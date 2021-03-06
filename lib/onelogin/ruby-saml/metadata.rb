require "rexml/document"
require "rexml/xpath"
require "net/https"
require "uri"
require "digest/md5"

# Class to return SP metadata based on the settings requested.
# Return this XML in a controller, then give that URL to the the 
# IdP administrator.  The IdP will poll the URL and your settings
# will be updated automatically
module Onelogin
  module Saml
    class Metadata
      include REXML
      include Coding
      # a few symbols for SAML class names
      HTTP_POST = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
      HTTP_GET = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"

      def initialize(settings=nil)
        if settings
          @settings = settings
        end
      end

      def generate(settings)
        meta_doc = REXML::Document.new
        root = meta_doc.add_element "md:EntityDescriptor", { 
            "xmlns:md"        => "urn:oasis:names:tc:SAML:2.0:metadata",
            "xmlns:xml"       => "http://www.w3.org/XML/1998/namespace",
            "cacheDuration"   => "P1M" 
        }
        if settings.issuer != nil
          root.attributes["entityID"] = settings.issuer
        end
        sp_sso = root.add_element "md:SPSSODescriptor", { 
            "protocolSupportEnumeration" => "urn:oasis:names:tc:SAML:2.0:protocol",
            "WantAssertionsSigned"       => "true"

        }
          name_identifier_formats = settings.name_identifier_format
          if name_identifier_formats != nil
            name_id = []
            name_identifier_formats.each_with_index{ |format, index|
              name_id[index] = sp_sso.add_element "md:NameIDFormat"
              name_id[index].text = format
            }
            
          end
          if settings.sp_cert != nil
            keyDescriptor = sp_sso.add_element "md:KeyDescriptor", {
              "use" => "signing"
            }
            keyInfo = keyDescriptor.add_element "ds:KeyInfo", {
              "xmlns:ds" => "http://www.w3.org/2000/09/xmldsig#"
            }
            x509Data = keyInfo.add_element "ds:X509Data"
            x509Certificate = x509Data.add_element "ds:X509Certificate"
            file = ""
            File.foreach(settings.sp_cert){ |line|
                                         file  += line unless (line.include?("RSA PUBLIC KEY") || line.include?("CERTIFICATE")) 
                                       }
            x509Certificate.text = file                            
          end
          if settings.assertion_consumer_service_url != nil
            sp_sso.add_element "md:AssertionConsumerService", {
                # Add this as a setting to create different bindings?
                "Binding" => "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST",
                "Location" => settings.assertion_consumer_service_url,
                "index" => "1"
            }
          end
          if settings.single_logout_service_url != nil
            sp_sso.add_element "md:SingleLogoutService", {
                "Binding" => "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect",
                "Location" => settings.single_logout_service_url
            }
            sp_sso.add_element "md:SingleLogoutService", {
                "Binding" => "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST",
                "Location" => settings.single_logout_service_url
            }
          end
        meta_doc << REXML::XMLDecl.new(version='1.0', encoding='UTF-8')
        ret = ""
        # pretty print the XML so IdP administrators can easily see what the SP supports
        meta_doc.write(ret, 1)

        #Logging.debug "Generated metadata:\n#{ret}"

        return ret

      end

      def create_sso_request(message, extra_parameters = {} )
        build_message( :type => "SAMLRequest", 
            :service => "SingleSignOnService", 
            :message => message, :extra_parameters => extra_parameters)
      end
      def create_sso_response(message, extra_parameters = {} )
        build_message( :type => "SAMLResponse", 
            :service => "SingleSignOnService", 
            :message => message, :extra_parameters => extra_parameters)     
      end
      def create_slo_request(message, extra_parameters = {} )
        build_message( :type => "SAMLRequest", 
            :service => "SingleLogoutService", 
            :message => message, :extra_parameters => extra_parameters)
      end
      def create_slo_response(message, extra_parameters = {} )
        build_message( :type => "SAMLResponse", 
            :service => "SingleLogoutService", 
            :message => message, :extra_parameters => extra_parameters)     
      end

      # Construct a SAML message using information in the IdP metadata.  
      # :type can be either "SAMLRequest" or "SAMLResponse" 
      # :service refers to the Binding method, 
      #    either "SingleLogoutService" or "SingleSignOnService"
      # :message is the SAML message itself (XML)  
      # I've provided easy to use wrapper functions above 
      def build_message( options = {} )
        opt = { :type => nil, :service => nil, :message => nil, :extra_parameters => nil }.merge(options)
        url = binding_select( opt[:service] )
        return message_get( opt[:type], url, opt[:message], opt[:extra_parameters] )
      end

      # get the IdP metadata, and select the appropriate SSO binding
      # that we can support.  Currently this is HTTP-Redirect and HTTP-POST
      # but more could be added in the future
      def binding_select(service)
        # first check if we're still using the old hard coded method for 
        # backwards compatability
        if service == "SingleSignOnService" && @settings.idp_metadata == nil && @settings.idp_sso_target_url != nil
            return @settings.idp_sso_target_url
        end
        if service == "SingleLogoutService" && @settings.idp_metadata == nil && @settings.idp_slo_target_url != nil
            return  @settings.idp_slo_target_url
        end
        
        meta_doc = get_idp_metadata
        
        return nil unless meta_doc
        # first try POST
        sso_element = REXML::XPath.first(meta_doc, "/md:EntityDescriptor/md:IDPSSODescriptor/md:#{service}[@Binding='#{HTTP_POST}']")
        if !sso_element.nil? 
          @URL = sso_element.attributes["Location"]
          #Logging.debug "binding_select: POST to #{@URL}"
          return @URL
        end
        
        # next try GET
        sso_element = REXML::XPath.first(meta_doc, "/md:EntityDescriptor/md:IDPSSODescriptor/md:#{service}[@Binding='#{HTTP_GET}']")
        if !sso_element.nil? 
          @URL = sso_element.attributes["Location"]
          Logging.debug "binding_select: GET from #{@URL}"
          return @URL
        end
        # other types we might want to add in the future:  SOAP, Artifact
      end

      # Retrieve the remote IdP metadata from the URL or a cached copy 
      # returns a REXML document of the metadata
      def get_idp_metadata
        return false if @settings.idp_metadata.nil?
      
        # Look up the metdata in cache first
        id = Digest::MD5.hexdigest(@settings.idp_metadata)

        uri = URI.parse(@settings.idp_metadata)
        if uri.scheme == "http"
          response = Net::HTTP.get_response(uri)
          meta_text = response.body
        elsif uri.scheme == "https"
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          # Most IdPs will probably use self signed certs
          #http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          get = Net::HTTP::Get.new(uri.request_uri)
          response = http.request(get)
          meta_text = response.body
        end
        testo_response = meta_text.sub!(' xmlns:xml="http://www.w3.org/XML/1998/namespace"', '')
        doc = REXML::Document.new(testo_response)
        extract_certificate(doc)
        return doc


        # lookup = @cache.read(id)
        # if lookup != nil
        #   Logging.debug "IdP metadata cached lookup for #{@settings.idp_metadata}"
        #   doc = REXML::Document.new( lookup )
        #   extract_certificate( doc )
        #   return doc
        # end
        
        # Logging.debug "IdP metadata cache miss on #{@settings.idp_metadata}"
        # # cache miss
        # if File.exists?(@settings.idp_metadata)
        #   fp = File.open( @settings.idp_metadata, "r")
        #   meta_text = fp.read
        # else
        #   uri = URI.parse(@settings.idp_metadata)
        #   if uri.scheme == "http"
        #     response = Net::HTTP.get_response(uri)
        #     meta_text = response.body
        #   elsif uri.scheme == "https"
        #     http = Net::HTTP.new(uri.host, uri.port)
        #     http.use_ssl = true
        #     # Most IdPs will probably use self signed certs
        #     #http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        #     http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        #     get = Net::HTTP::Get.new(uri.request_uri)
        #     response = http.request(get)
        #     meta_text = response.body
        #   end
        # end
        # # Add it to the cache
        # @cache.write(id, meta_text, @settings.idp_metadata_ttl )
        # doc = REXML::Document.new( meta_text )
        # extract_certificate(doc)
        # return doc
      end

      def extract_certificate(meta_doc)

        # pull out the x509 tag
        x509 = REXML::XPath.first(meta_doc, "/md:EntityDescriptor/md:IDPSSODescriptor"+"/md:KeyDescriptor"+"/ds:KeyInfo/ds:X509Data/ds:X509Certificate"
            )
        # If the IdP didn't specify the use attribute
        if x509.nil?
          x509 = REXML::XPath.first(meta_doc, 
                "/EntityDescriptor/IDPSSODescriptor" +
              "/KeyDescriptor" +
              "/ds:KeyInfo/ds:X509Data/ds:X509Certificate"
            )
        end
        @settings.idp_cert = x509.text.gsub(/\n/, "").gsub(/\t/, "")
      end

      # construct the parameter list on the URL and return
      def message_get( type, url, message, extra_parameters = {} )

        params = Hash.new
        if extra_parameters
          params.merge!(extra_parameters)
        end
        # compress GET requests to try and stay under that 8KB request limit
        
        #fa il deflate di samlrequest
        params[type] = encode( deflate( message ) )
        
        Logging.debug "#{type}=#{params[type]}"
        
        uri = Addressable::URI.parse(url)
        if uri.query_values == nil
          uri.query_values = params
        else
          # solution to stevenwilkin's parameter merge
          uri.query_values = params.merge(uri.query_values)
        end
        url = uri.to_s
        #url = @URL + "?SAMLRequest=" + @request_params["SAMLRequest"]
        Logging.debug "Sending to URL #{url}"
        return url
      end

    end
  end
end
