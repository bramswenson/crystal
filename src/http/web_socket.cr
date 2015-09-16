require "socket"
require "http"
require "base64"
require "openssl"
require "uri"

class HTTP::WebSocket
  enum Opcode : UInt8
    CONTINUATION   = 0x0
    TEXT           = 0x1
    BINARY         = 0x2
    CLOSE          = 0x8
    PING           = 0x9
    PONG           = 0xA
  end

  MASK_BIT      = 128_u8
  VERSION       = 13

  record PacketInfo, opcode, size, final

  def initialize(@io)
    @header :: UInt8[2]
    @mask :: UInt8[4]
    @mask_offset = 0
    @opcode = Opcode::CONTINUATION
    @remaining = 0
  end

  def send(data)
    write_header(data.size)
    @io.print data
    @io.flush
  end

  def send_masked(data)
    write_header(data.size, true)

    mask_array = StaticArray(UInt8, 4).new { rand(256).to_u8 }
    @io.write mask_array.to_slice

    data.size.times do |index|
      mask = mask_array[index % 4]
      @io.write_byte (mask ^ data.byte_at(index).to_u8).to_u8
    end
    @io.flush
  end

  private def write_header(size, masked = false)
    @io.write_byte(0x81_u8)

    mask = masked ? MASK_BIT : 0
    if size <= 125
      @io.write_byte(size.to_u8 | mask)
    elsif size <= UInt16::MAX
      @io.write_byte(126_u8 | mask)
      1.downto(0) { |i| @io.write_byte((size >> i * 8).to_u8) }
    else
      @io.write_byte(127_u8 | mask)
      3.downto(0) { |i| @io.write_byte((size >> i * 8).to_u8) }
    end
  end

  def receive(buffer : Slice(UInt8))
    if @remaining == 0
      opcode = read_header
    else
      opcode = @opcode
    end

    read = @io.read buffer[0, Math.min(@remaining, buffer.size)]
    @remaining -= read

    # Unmask payload, if needed
    if masked?
      read.times do |i|
        buffer[i] ^= @mask[@mask_offset % 4]
        @mask_offset += 1
      end
    end

    PacketInfo.new(opcode, read.to_i, final? && @remaining == 0)
  end

  private def read_header
    # First byte: FIN (1 bit), RSV1,2,3 (3 bits), Opcode (4 bits)
    # Second byte: MASK (1 bit), Payload Length (7 bits)
    @io.read_fully(@header.to_slice)

    opcode = read_opcode
    @remaining = read_size

    # Read mask, if needed
    if masked?
      @io.read_fully(@mask.to_slice)
      @mask_offset = 0
    end

    opcode
  end

  private def read_opcode
    raw_opcode = @header[0] & 0x0f_u8
    parsed_opcode = Opcode.from_value?(raw_opcode)
    unless parsed_opcode
      raise "Invalid packet opcode: #{raw_opcode}"
    end

    if parsed_opcode == Opcode::CONTINUATION
       @opcode
     elsif control?
       parsed_opcode
     else
       @opcode = parsed_opcode
     end
  end

  private def read_size
    size = (@header[1] & 0x7f_u8).to_i
    if size == 126
      size = 0
      2.times { size <<= 8; size += @io.read_byte.not_nil! }
    elsif size == 127
      size = 0
      4.times { size <<= 8; size += @io.read_byte.not_nil! }
    end
    size
  end

  private def control?
    (@header[0] & 0x08_u8) != 0_u8
  end

  private def final?
    (@header[0] & 0x80_u8) != 0_u8
  end

  private def masked?
    (@header[1] & 0x80_u8) != 0_u8
  end

  def close
  end

  # Opens a new websocket to the target host. This will also handle the handshake
  # and will raise an exception if the handshake did not complete successfully.
  #
  # ```
  # WebSocket.open("websocket.example.com", "/chat")              # Creates a new WebSocket to `websocket.example.com`
  # WebSocket.open("websocket.example.com", "/chat", ssl = true)  # Creates a new WebSocket with SSL to `ẁebsocket.example.com`
  # ```
  def self.open(host, path, port = nil, ssl = false)
    port = port || (ssl ? 443 : 80)
    socket = TCPSocket.new(host, port)
    socket = OpenSSL::SSL::Socket.new(socket) if ssl

    headers = HTTP::Headers.new
    headers["Host"] = "#{host}:#{port}"
    headers["Connection"] = "Upgrade"
    headers["Upgrade"] = "websocket"
    headers["Sec-WebSocket-Version"] = VERSION.to_s
    headers["Sec-WebSocket-Key"] = Base64.encode(StaticArray(UInt8, 16).new { rand(256).to_u8 })

    path = "/" if path.empty?
    handshake = HTTP::Request.new("GET", path, headers)
    handshake.to_io(socket)
    handshake_response = HTTP::Response.from_io(socket)
    unless handshake_response.status_code == 101
      raise Socket::Error.new("Handshake got denied. Status code was #{handshake_response.status_code}")
    end

    new(socket)
  end

  # Opens a new websocket using the information provided by the URI. This will also handle the handshake
  # and will raise an exception if the handshake did not complete successfully. This method will also raise
  # an exception if the URI is missing the host and/or the path.
  #
  # Please note that the scheme will only be used to identify if SSL should be used or not. Therefore, schemes
  # apart from `wss` and `https` will be treated as the default which is `ws`.
  #
  # ```
  # WebSocket.open(URI.parse("ws://websocket.example.com/chat"))        # Creates a new WebSocket to `websocket.example.com`
  # WebSocket.open(URI.parse("wss://websocket.example.com/chat"))       # Creates a new WebSocket with SSL to `websocket.example.com`
  # WebSocket.open(URI.parse("http://websocket.example.com:8080/chat")) # Creates a new WebSocket to `websocket.example.com` on port `8080`
  # ```
  def self.open(uri : URI | String)
    uri = URI.parse(uri) if uri.is_a?(String)

    if host = uri.host
      if path = uri.path
        ssl = uri.scheme == "https" || uri.scheme == "wss"
        return open(host, path, uri.port, ssl)
      end
    end

    raise ArgumentError.new("No host or path specified which are required.")
  end
end