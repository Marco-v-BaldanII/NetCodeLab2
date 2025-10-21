extends Node
class_name Server

var tcp_server = TCPServer.new()
var udp_server = UDPServer.new()

# List to store connected StreamPeerTCP objects (one for each client)
var tcp_peers = [] 
const TCP_PORT = 5000
const UDP_PORT = 5001

func _ready():
	
	var tcp_error = tcp_server.listen(TCP_PORT)
	var udp_error = udp_server.listen(UDP_PORT)

	if tcp_error == OK and udp_error == OK:
		print("Server is listening. TCP on %d, UDP on %d." % [TCP_PORT, UDP_PORT])
	else:
		print("Failed to start server. TCP Error: %d, UDP Error: %d" % [tcp_error, udp_error])



func _process(delta):
	# --- Polling for New TCP Connections ---
	if tcp_server.is_listening() and tcp_server.is_connection_available():
		var new_peer : StreamPeerTCP = tcp_server.take_connection() # Non-blocking accept
		tcp_peers.append(new_peer)
		print("New TCP Client connected! Total peers: ", tcp_peers.size())
		
		# Answer with the name of the server
		send_tcp_message(new_peer, "Server_Godot_Online")
		
	# --- Polling for TCP Data on Existing Peers ---
	# Iterate backward so removing a peer doesn't mess up the index 'i'
	for i in range(tcp_peers.size() - 1, -1, -1):
		var peer = tcp_peers[i]
		peer.poll() #  poll to update status and buffers
		
		# Check for disconnection
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			print("TCP Client disconnected.")
			tcp_peers.remove(i)
			continue # Go to the next peer
			
		# Check for data
		if peer.get_available_bytes() >= 4: # Read the 4-byte length prefix first
			var packet_length = peer.get_u32()

			# Ensure the full packet has arrived before reading
			if peer.get_available_bytes() >= packet_length:
				# get_data returns [error_code, PackedByteArray]
				var data_result = peer.get_data(packet_length) 
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					var message = data_bytes.get_string_from_utf8()
					print("Received TCP message: ", message)
					# Respond to show the connection is working
					send_tcp_message(peer, "TCP_ECHO: " + message)
				
	# --- Polling for UDP Packets/New Connections ---
	if udp_server.is_listening():
		udp_server.poll() # process new packets and check for new peers
		
		
		if udp_server.is_connection_available():
			# take_connection() returns a PacketPeerUDP connected to the sender
			var peer: PacketPeerUDP = udp_server.take_connection() 
			
			if peer:
				# This created peer has the first packet avilable
				while peer.get_available_packet_count() > 0: 
					var packet = peer.get_packet()
					var message = packet.get_string_from_utf8()
					
					# Through the peer get the sender's info
					var ip = peer.get_packet_ip()
					var port = peer.get_packet_port()

					print("Accepted new UDP peer: %s:%d" % [ip, port])
					print("Received UDP data: %s" % message)
					
					# Reply using the peer, since it is already configured
					peer.put_packet("UDP Server ACK".to_utf8_buffer())

# Helper function to send data with a 4-byte length prefi
func send_tcp_message(peer : StreamPeerTCP, message : String):
	var encoded_data = message.to_utf8_buffer()
	peer.put_u32(encoded_data.size()) 
	peer.put_data(encoded_data)
