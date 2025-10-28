extends Node

# signal for when chat info arrives
signal chat_message_received(message: String)
# signal for general server status updates
signal server_status_update(message: String)


var tcp_peer = StreamPeerTCP.new()
var udp_peer = PacketPeerUDP.new()


const SERVER_IP = "127.0.0.1" # Loopback adress
const TCP_PORT = 5000
const UDP_PORT = 5001

func _ready():
	connect_to_server(SERVER_IP)

func connect_to_server(ip_address):
	# Connect the TCP Peer 
	var tcp_error = tcp_peer.connect_to_host(ip_address, TCP_PORT)
	if tcp_error != OK:
		print("TCP connection attempt failed:", tcp_error)
		emit_signal("server_status_update", "Connection Failed: TCP Error %d" % tcp_error)
		
	# UDP Peer connectionless setup
	udp_peer.set_dest_address(ip_address, UDP_PORT)
	print("UDP client destination set to %s:%d" % [ip_address, UDP_PORT])
	
	# Send a message after a short delay (gives the TCP connect time to finish)
	call_deferred("send_initial_messages")


#  Public function for other scripts (like UI) to call ---
func send_chat_message(message_content: String):
	if message_content == "":
		return
		
	# The server expects a prefix, so the server script knows to broadcast this
	var prefixed_message = "CHAT_MSG: [You]: " + message_content
	send_tcp_message(prefixed_message)


func send_initial_messages():
	# Wait to resolve connection attempt
	await get_tree().create_timer(1).timeout
	
	# Sends a message with the user's name
	send_tcp_message("Client: User_A is joining via TCP.")
	send_udp_message("Client: User_A is sending a UDP message.")
	

func send_tcp_message(message):
	if tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var encoded_data = message.to_utf8_buffer()
		#TCP requires a length prefix (4 bytes)
		tcp_peer.put_u32(encoded_data.size()) 
		tcp_peer.put_data(encoded_data)
		print("Sent TCP message: ", message)
	else:
		print("TCP not connected (Status: %d), cannot send." % tcp_peer.get_status())


func send_udp_message(message):
	var encoded_data = message.to_utf8_buffer()
	udp_peer.put_packet(encoded_data)
	print("Sent UDP message: ", message)


func _process(delta):
	# --- TCP Polling ---
	tcp_peer.poll() # Updates peer status and buffers

	if tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		# Checks if enough bytes are available to read the 4-byte length prefix
		if tcp_peer.get_available_bytes() >= 4:
			var packet_length = tcp_peer.get_u32()

			# Ensure the full packet has arrived before reading
			if tcp_peer.get_available_bytes() >= packet_length:
				var data_result = tcp_peer.get_data(packet_length) 
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					var received_string = data_bytes.get_string_from_utf8()
					
					# Deal with Messages from the chat
					if received_string.begins_with("[CHAT]"):
						var chat_content = received_string.trim_prefix("[CHAT]").strip_edges()
						emit_signal("chat_message_received", chat_content)
					else:
						# All other messages 
						emit_signal("server_status_update", received_string)
	
	# ---UDP Polling ---
	while udp_peer.get_available_packet_count() > 0:
		var packet = udp_peer.get_packet()
		var received_string = packet.get_string_from_utf8()
		
		emit_signal("server_status_update", "UDP Reply: " + received_string)
