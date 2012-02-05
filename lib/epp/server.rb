module Epp #:nodoc:
  class Server
    include RequiresParameters
        
    attr_accessor :tag, :password, :server, :port, :clTRID, :old_server
    
    # ==== Required Attrbiutes
    # 
    # * <tt>:server</tt> - The EPP server to connect to
    # * <tt>:tag</tt> - The tag or username used with <tt><login></tt> requests.
    # * <tt>:password</tt> - The password used with <tt><login></tt> requests.
    # 
    # ==== Optional Attributes
    #
    # * <tt>:port</tt> - The EPP standard port is 700. However, you can choose a different port to use.
    # * <tt>:clTRID</tt> - The client transaction identifier is an element that EPP specifies MAY be used to uniquely identify the command to the server. You are responsible for maintaining your own transaction identifier space to ensure uniqueness. Defaults to "ABC-12345"
    # * <tt>:old_server</tt> - Set to true to read and write frames in a way that is compatible with old EPP servers. Default is false.
    # * <tt>:lang</tt> - Set custom language attribute. Default is 'en'.
    def initialize(attributes = {})
      requires!(attributes, :tag, :password, :server)
      
      @tag         = attributes[:tag]
      @password    = attributes[:password]
      @server      = attributes[:server]
      @port        = attributes[:port] || 700
      @clTRID      = attributes[:clTRID] || "ABC-12345"
      @old_server  = attributes[:old_server] || false
      @lang        = attributes[:lang] || 'en'
      @ssl_version = attributes[:ssl_version]
    end
    
    # Sends an XML request to the EPP server, and receives an XML response. 
    # <tt><login></tt> and <tt><logout></tt> requests are also wrapped
    # around the request, so we can close the socket immediately after
    # the request is made.
    def request(xml)
      open_connection
      
      begin
        login
        @response = send_request(xml)
      ensure
        logout unless @old_server
        close_connection
      end
      
      return @response
    end
    
    # private
    
    # Wrapper which sends an XML frame to the server, and receives 
    # the response frame in return.
    def send_request(xml)
      send_frame(xml)
      response = get_frame
    end
    
    def login
      xml = REXML::Document.new
      xml << REXML::XMLDecl.new("1.0", "UTF-8", "no")
      
      xml.add_element("epp", {
        "xmlns" => "urn:ietf:params:xml:ns:epp-1.0",
        "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance",
        "xsi:schemaLocation" => "urn:ietf:params:xml:ns:epp-1.0 epp-1.0.xsd"
      })
      
      command = xml.root.add_element("command")
      login = command.add_element("login")
      
      login.add_element("clID").text = @tag
      login.add_element("pw").text = @password
      
      options = login.add_element("options")
      options.add_element("version").text = "1.0"
      options.add_element("lang").text = @lang
      
      services = login.add_element("svcs")
      services.add_element("objURI").text = "urn:ietf:params:xml:ns:domain-1.0"
      services.add_element("objURI").text = "urn:ietf:params:xml:ns:contact-1.0"
      services.add_element("objURI").text = "urn:ietf:params:xml:ns:host-1.0"
      
      command.add_element("clTRID").text = @clTRID

      # Receive the login response
      response = Hpricot.XML(send_request(xml.to_s))

      result_message  = (response/"epp"/"response"/"result"/"msg").text.strip
      result_code     = (response/"epp"/"response"/"result").attr("code").to_i
   
      if result_code == 1000
        return true
      else
        raise EppErrorResponse.new(:code => result_code, :message => result_message)
      end
    end
    
    def logout
      xml = REXML::Document.new
      xml << REXML::XMLDecl.new("1.0", "UTF-8", "no")
      
      xml.add_element('epp', {
        'xmlns' => "urn:ietf:params:xml:ns:epp-1.0",
        'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
        'xsi:schemaLocation' => "urn:ietf:params:xml:ns:epp-1.0 epp-1.0.xsd"
      })
      
      command = xml.root.add_element("command")
      login = command.add_element("logout")
      
      # Receive the logout response
      response = Hpricot.XML(send_request(xml.to_s))
      
      result_message  = (response/"epp"/"response"/"result"/"msg").text.strip
      result_code     = (response/"epp"/"response"/"result").attr("code").to_i
      
      if result_code == 1500
        return true
      else
        raise EppErrorResponse.new(:code => result_code, :message => result_message)
      end
    end
    
    # Establishes the connection to the server. If the connection is
		# established, then this method will call get_frame and return 
		# the EPP <tt><greeting></tt> frame which is sent by the 
		# server upon connection.
    def open_connection
      @connection = TCPSocket.new(@server, @port)
      @socket     = OpenSSL::SSL::SSLSocket.new(@connection)
      @socket.context.ssl_version = @ssl_version if @ssl_version
      
      # Synchronously close the connection & socket
      @socket.sync_close
      
      # Connect
      @socket.connect
      
      # Get the initial frame
      get_frame
    end
    
    # Closes the connection to the EPP server.
    def close_connection
      if defined?(@socket) and @socket.is_a?(OpenSSL::SSL::SSLSocket)
        @socket.close
        @socket = nil
      end
      
      if defined?(@connection) and @connection.is_a?(TCPSocket)
        @connection.close
        @connection = nil
      end
      
      return true if @connection.nil? and @socket.nil?
    end
    
    # Receive an EPP frame from the server. Since the connection is blocking,
    # this method will wait until the connection becomes available for use. If
    # the connection is broken, a SocketError will be raised. Otherwise,
    # it will return a string containing the XML from the server.
    def get_frame
       if @old_server
          data = ''
          first_char = @socket.read(1)
          if first_char.nil? and @socket.eof?
            raise SocketError.new("Connection closed by remote server")
          elsif first_char.nil?
            raise SocketError.new("Error reading frame from remote server")
          else
             data << first_char
             while char = @socket.read(1)
                data << char
                return data if data =~ %r|<\/epp>\n$|mi # at end
             end
          end
       else
          header = @socket.read(4)

          if header.nil? and @socket.eof?
            raise SocketError.new("Connection closed by remote server")
          elsif header.nil?
            raise SocketError.new("Error reading frame from remote server")
          else
            unpacked_header = header.unpack("N")
            length = unpacked_header[0]

            if length < 5
              raise SocketError.new("Got bad frame header length of #{length} bytes from the server")
            else
              response = @socket.read(length - 4)   
            end
          end
       end      
    end

    # Send an XML frame to the server. Should return the total byte
    # size of the frame sent to the server. If the socket returns EOF,
    # the connection has closed and a SocketError is raised.
    def send_frame(xml)      
       @socket.write( @old_server ? (xml + "\r\n") : ([xml.size + 4].pack("N") + xml) )
    end
  end
end
