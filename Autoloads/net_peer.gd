extends Node
# Autoload: NetPeer

# --- STATE MANAGEMENT ---
enum NetMode { DISCONNECTED, HOST, CLIENT }
var current_mode = NetMode.DISCONNECTED

# --- SIGNALS (The communication channel for your UI/Game Logic) ---
signal chat_message_received(message: String)
signal server_status_update(message: String)
signal peer_connected(id)
signal peer_disconnected(id)

# --- CONSTANTS ---
const SERVER_IP = "127.0.0.1" 
const TCP_PORT = 5000
const UDP_PORT = 5001

# --- SOCKETS (The plumbing) ---

# Sockets used when current_mode == CLIENT
var client_tcp_peer = StreamPeerTCP.new()
var client_udp_peer = PacketPeerUDP.new()

# Sockets and Lists used when current_mode == HOST
var host_tcp_server = TCPServer.new()
var host_udp_server = UDPServer.new()
var host_tcp_peers = [] # Stores StreamPeerTCP objects for connected clients


# =========================================================================
# === 1. PUBLIC INITIALIZATION FUNCTIONS (CALLED BY UI SCENES) ===
# =========================================================================

# Called by the "Create Game" UI scene
func init_host():
	if current_mode != NetMode.DISCONNECTED: return
	current_mode = NetMode.HOST
	start_server()
	print("NetPeer initialized as HOST.")

# Called by the "Join Game" UI scene
func init_client(ip_address):
	if current_mode != NetMode.DISCONNECTED: return
	current_mode = NetMode.CLIENT
	connect_to_server(ip_address)
	print("NetPeer initialized as CLIENT, connecting to %s." % ip_address)
	
# =========================================================================
# === 2. SETUP FUNCTIONS (CALLED INTERNALLY) ===
# =========================================================================

# --- HOST Setup ---
func start_server():
	var tcp_error = host_tcp_server.listen(TCP_PORT)
	if tcp_error != OK:
		print("TCP Server failed to listen:", tcp_error)
		emit_signal("server_status_update", "Host Failed: TCP Error %d" % tcp_error)
		return
		
	var udp_error = host_udp_server.listen(UDP_PORT)
	if udp_error != OK:
		print("UDP Server failed to listen:", udp_error)

	emit_signal("server_status_update", "Server is listening. TCP on %d, UDP on %d." % [TCP_PORT, UDP_PORT])

# --- CLIENT Setup ---
func connect_to_server(ip_address):
	var tcp_error = client_tcp_peer.connect_to_host(ip_address, TCP_PORT)
	if tcp_error != OK:
		print("TCP connection attempt failed:", tcp_error)
		emit_signal("server_status_update", "Connection Failed: TCP Error %d" % tcp_error)
		
	client_udp_peer.set_dest_address(ip_address, UDP_PORT)
	print("UDP client destination set to %s:%d" % [ip_address, UDP_PORT])
	
	call_deferred("send_initial_messages")

func send_initial_messages():
	await get_tree().create_timer(1).timeout
	
	send_tcp_message_as_client("Client: User_A is joining via TCP.")
	send_udp_message_as_client("Client: User_A is sending a UDP message.")

# =========================================================================
# === 3. SENDING FUNCTIONS (MODULAR) ===
# =========================================================================

# Public function used by UI to send a chat message
func send_chat_message(message_content: String):
	if message_content == "" or current_mode == NetMode.DISCONNECTED: return
	
	var sender_name = "[Host]: " if current_mode == NetMode.HOST else "[You]: "
	var full_message = sender_name + message_content
	
	# Emit signal so the local UI updates itself (local echo)
	emit_signal("chat_message_received", full_message)
	
	if current_mode == NetMode.HOST:
		# Host: Broadcasts to all clients
		broadcast_tcp_message(null, full_message)
	elif current_mode == NetMode.CLIENT:
		# Client: Sends prefixed message to the server
		var prefixed_message = "CHAT_MSG: " + full_message
		send_tcp_message_as_client(prefixed_message)

# Helper for Clients (sends to the one server)
func send_tcp_message_as_client(message):
	if client_tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var encoded_data = message.to_utf8_buffer()
		client_tcp_peer.put_u32(encoded_data.size()) 
		client_tcp_peer.put_data(encoded_data)
		print("Sent TCP message (C->S): ", message)
	else:
		print("Client TCP not connected, cannot send.")

# Helper for Clients (sends to the one server)
func send_udp_message_as_client(message):
	var encoded_data = message.to_utf8_buffer()
	client_udp_peer.put_packet(encoded_data)
	print("Sent UDP message (C->S): ", message)

# Helper for Host (sends to multiple clients)
func broadcast_tcp_message(sender_peer, message):
	var full_message = "[CHAT] " + message
	var encoded_data = full_message.to_utf8_buffer()
	var packet_size = encoded_data.size()
	
	for peer in host_tcp_peers:
		# Do NOT send to the original sender, UNLESS the sender is the Host (null)
		if peer != sender_peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.put_u32(packet_size) 
			peer.put_data(encoded_data)
	
# =========================================================================
# === 4. POLLING LOOP (_PROCESS) ===
# =========================================================================

func _process(delta):
	if current_mode == NetMode.HOST:
		poll_as_host()
	elif current_mode == NetMode.CLIENT:
		poll_as_client()
	
# --- HOST POLLING LOGIC ---
func poll_as_host():
	# 1. TCP Accept New Connections
	if host_tcp_server.is_listening() and host_tcp_server.is_connection_available():
		var new_peer = host_tcp_server.take_connection()
		host_tcp_peers.append(new_peer)
		print("New TCP Client connected! Total peers: %d" % host_tcp_peers.size())
		emit_signal("peer_connected", host_tcp_peers.size())
		
		# Send initial reply
		broadcast_tcp_message(new_peer, "Server_Godot_Online")
	
	# 2. TCP Read from Existing Clients
	for i in range(host_tcp_peers.size() - 1, -1, -1):
		var peer = host_tcp_peers[i]
		peer.poll()
		
		# Handle disconnection
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			host_tcp_peers.remove_at(i)
			print("TCP Client disconnected. Total peers: %d" % host_tcp_peers.size())
			emit_signal("peer_disconnected", host_tcp_peers.size())
			continue
		
		# Read data with length prefix check (same as before)
		if peer.get_available_bytes() >= 4:
			var packet_length = peer.get_u32()
			if peer.get_available_bytes() >= packet_length:
				var data_result = peer.get_data(packet_length) 
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					var message = data_bytes.get_string_from_utf8()
					
					# Process Message
					if message.begins_with("CHAT_MSG:"):
						var chat_content = message.trim_prefix("CHAT_MSG:")
						# Broadcast the message to all OTHER clients
						broadcast_tcp_message(peer, chat_content)
						# Update the Host's own chat history
						emit_signal("chat_message_received", chat_content) 
					else:
						# LAB REQUIREMENT: Echo non-chat messages
						send_tcp_message_as_host(peer, "TCP_ECHO: " + message)
				
	# 3. UDP Polling
	if host_udp_server.is_listening():
		host_udp_server.poll()
		while host_udp_server.is_connection_available():
			var peer = host_udp_server.take_connection()
			while peer.get_available_packet_count() > 0:
				var packet = peer.get_packet()
				var received_string = packet.get_string_from_utf8()
				
				# Send UDP ACK reply
				var ack_packet = "UDP Server ACK".to_utf8_buffer()
				peer.put_packet(ack_packet)
				
				emit_signal("server_status_update", "Received UDP data from client, sent ACK.")

# Helper for Host (sends general message back to one peer)
func send_tcp_message_as_host(peer, message):
	var encoded_data = message.to_utf8_buffer()
	peer.put_u32(encoded_data.size()) 
	peer.put_data(encoded_data)

# --- CLIENT POLLING LOGIC ---
func poll_as_client():
	# 1. TCP Polling
	client_tcp_peer.poll()

	if client_tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if client_tcp_peer.get_available_bytes() >= 4:
			var packet_length = client_tcp_peer.get_u32()

			if client_tcp_peer.get_available_bytes() >= packet_length:
				var data_result = client_tcp_peer.get_data(packet_length) 
				
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
	
	# 2. UDP Polling
	while client_udp_peer.get_available_packet_count() > 0:
		var packet = client_udp_peer.get_packet()
		var received_string = packet.get_string_from_utf8()
		
		emit_signal("server_status_update", "UDP Reply: " + received_string)
