extends Node
# Autoload: NetPeer

enum NetMode { DISCONNECTED, HOST, CLIENT }
var current_mode = NetMode.DISCONNECTED:
	set(val):
		current_mode = val

signal chat_message_received(message: String)
signal server_status_update(message: String)
signal peer_connected(id)
signal peer_disconnected(id)

const SERVER_IP = "127.0.0.1"
const TCP_PORT = 5000
const UDP_PORT = 5001

# --- SYNCHRONIZATION CONSTANTS ---
const PACKET_TYPE_SYNC = 0x01
const NETID_ASSIGNMENT = "NETID_ASSIGNMENT:"

var client_tcp_peer = StreamPeerTCP.new()
var client_udp_peer = PacketPeerUDP.new()

# Sockets and Lists used when current_mode is HOST
var host_tcp_server = TCPServer.new()
var host_udp_server = UDPServer.new()
var host_tcp_peers = []
var initialized_peers = {} # Host tracks StreamPeerTCPs that have received initial sync

# --- SYNCHRONIZATION REGISTRY (The Server's Key) ---
var next_net_id : int = 100
# Dictionary of Ids and synchronizers
var net_id_to_synchronizer_map : Dictionary = {}


var local_client_id : int = -1 # 0 host, 1 client

func init_host():
	if current_mode != NetMode.DISCONNECTED: return
	current_mode = NetMode.HOST
	start_server()
	print("NetPeer initialized as HOST.")
	local_client_id = 0


func init_client(ip_address):
	if current_mode != NetMode.DISCONNECTED: return
	current_mode = NetMode.CLIENT
	connect_to_server(ip_address)
	print("NetPeer initialized as CLIENT, connecting to %s." % ip_address)
	local_client_id = 1


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


func send_chat_message(message_content: String):
	if message_content == "" or current_mode == NetMode.DISCONNECTED:
		return
	
	var sender_name = "[Host]: " if current_mode == NetMode.HOST else "[You]: "
	var full_message = sender_name + message_content
	
	emit_signal("chat_message_received", full_message)
	
	if current_mode == NetMode.HOST:
		broadcast_tcp_message(null, full_message)
	elif current_mode == NetMode.CLIENT:
		var prefixed_message = "CHAT_MSG: " + full_message
		send_tcp_message_as_client(prefixed_message)


# --- SYNCHRONIZATION LOGIC ---

func register_synchronizer(synchronizer_node: Synchronizer) -> int:
	var new_net_id = next_net_id
	net_id_to_synchronizer_map[new_net_id] = synchronizer_node
	next_net_id += 1
	return new_net_id

# MODIFIED: Use initialized_peers to filter broadcasts
func send_tcp_synchronization_data(data: PackedByteArray, network_object_id: int, target_peer: StreamPeerTCP = null):
	
	var stream = StreamPeerBuffer.new()
	
	# Write Synchronization Header
	stream.put_u8(PACKET_TYPE_SYNC)
	stream.put_u32(network_object_id)
	
	# Write Synchronization Payload (the serialized dictionary)
	stream.put_data(data)
	
	var final_payload = stream.data_array
	
	match current_mode:
		NetMode.HOST:
			if target_peer:
				# 1. Initial Snapshot: Send ONLY to the specified peer (bypasses initialization check)
				_send_framed_data_to_peer(target_peer, final_payload)
			else:
				# 2. Continuous Updates: Send ONLY to fully initialized peers (CRITICAL FILTER)
				for peer in host_tcp_peers:
					if initialized_peers.has(peer): # Only send to clients marked as ready
						_send_framed_data_to_peer(peer, final_payload)
		
		NetMode.CLIENT:
			# Client always sends ONLY to the Host
			_send_framed_data_to_peer(client_tcp_peer, final_payload)

# Helper to send a raw binary packet with framing
func _send_framed_data_to_peer(peer: StreamPeerTCP, data: PackedByteArray):
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		# Prefix with size (framing)
		peer.put_u32(data.size())
		# send the raw binary data
		peer.put_data(data)

func _route_synchronization_packet(data_bytes: PackedByteArray, sender_peer: StreamPeerTCP = null):
	var stream = StreamPeerBuffer.new()
	stream.data_array = data_bytes
	
	stream.get_u8() # Consume PACKET_TYPE_SYNC (1 byte)
	
	var network_id = stream.get_u32() # Consume Network ID (4 bytes)
	
	# CORRECTED: Calculate remaining bytes
	var remaining_size = stream.get_size() - stream.get_position()
	var sync_payload = stream.get_data(remaining_size)
	
	# Find corresponding synchronizer and receive data
	if net_id_to_synchronizer_map.has(network_id):
		var synchronizer_script : Synchronizer = net_id_to_synchronizer_map[network_id]
		
		if is_instance_valid(synchronizer_script):
			synchronizer_script.receive(sync_payload[1])
			print("SYNC Packet routed to NetID: ", network_id)
		else:
			# Clean up map if the node was deleted
			net_id_to_synchronizer_map.erase(network_id)
			push_warning("SYNC: Invalid instance found for NetID %d" % network_id)
	else:
		push_warning("SYNC: Failed to find object with Network ID: " + str(network_id))

	# Host rebroadcast logic
	if current_mode == NetMode.HOST and sender_peer != null:
		# The host only re-broadcasts the payload part of the packet (the data_bytes)
		for peer in host_tcp_peers:
			if peer != sender_peer:
				_send_framed_data_to_peer(peer, data_bytes) # data_bytes already has sync header

func send_tcp_message_as_client(message):
	if client_tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var encoded_data = message.to_utf8_buffer()
		client_tcp_peer.put_u32(encoded_data.size())
		client_tcp_peer.put_data(encoded_data)
		print("Sent TCP message (C->S): ", message)
	else:
		print("Client TCP not connected, cannot send.")


func send_udp_message_as_client(message):
	var encoded_data = message.to_utf8_buffer()
	client_udp_peer.put_packet(encoded_data)
	print("Sent UDP message (C->S): ", message)


func broadcast_tcp_message(sender_peer, message):
	var full_message = "[CHAT] " + message
	var encoded_data = full_message.to_utf8_buffer()
	var packet_size = encoded_data.size()
	
	for peer in host_tcp_peers:
		if peer != sender_peer and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			peer.put_u32(packet_size)
			peer.put_data(encoded_data)


func _process(delta):
	if current_mode == NetMode.HOST:
		poll_as_host()
	elif current_mode == NetMode.CLIENT:
		# CRITICAL: Call the async function without 'await' here to prevent blocking _process.
		poll_as_client()

var next_client_id : int = 2
var host_peers_by_id : Dictionary 

# MODIFIED: Added initialized_peers logic
func poll_as_host():
	# Accept New Connections
	if host_tcp_server.is_listening() and host_tcp_server.is_connection_available():
		var new_peer : StreamPeerTCP = host_tcp_server.take_connection()
		host_tcp_peers.append(new_peer)
		var assigned_id = next_client_id
		next_client_id += 1
		
		# Host is double-appending new_peer here, maintaining original structure.
		host_tcp_peers.append(new_peer) 
		host_peers_by_id[assigned_id] = new_peer 
		
		print("New TCP Client connected! Total peers: %d" % host_tcp_peers.size())
		emit_signal("peer_connected", host_tcp_peers.size())
		
		# Send initial peer ID assignment
		var initial_message : String = "SERVER_ID_ASSIGNMENT:%d" % assigned_id
		send_tcp_message_as_host(new_peer, initial_message)
		
		# --- 1. Send all existing NetID assignments to the new client (CRITICAL) ---
		for net_id in net_id_to_synchronizer_map:
			var sync_node : Synchronizer = net_id_to_synchronizer_map[net_id]
			# We use the parent's path to allow the client to find the local object
			var sync_path = sync_node.parent.get_path()
			
			var message = "%s%d:%s" % [NETID_ASSIGNMENT, net_id, sync_path]
			send_tcp_message_as_host(new_peer, message)

		# --- 2. Send the full synchronization snapshot ONLY to the new client ---
		send_synchronizers_in_tree(new_peer) # New logic: directs sync to one peer

		# NEW: Mark this peer as initialized (ready for continuous broadcasts)
		initialized_peers[new_peer] = true
		
		broadcast_tcp_message(new_peer, "Server_Godot_Online")
	
	# TCP from existing Clients
	for i in range(host_tcp_peers.size() - 1, -1, -1):
		var peer = host_tcp_peers[i]
		peer.poll()
		
		# Handle disconnection
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			# NEW: Clean up initialized_peers on disconnect
			if initialized_peers.has(peer):
				initialized_peers.erase(peer)
				
			host_tcp_peers.remove_at(i)
			print("TCP Client disconnected. Total peers: %d" % host_tcp_peers.size())
			emit_signal("peer_disconnected", host_tcp_peers.size())
			continue

		while peer.get_available_bytes() >= 4:
			
			var packet_length = peer.get_u32()
			
			if peer.get_available_bytes() >= packet_length:
				var data_result = peer.get_data(packet_length)
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					var packet_type = data_bytes[0]
					
					if packet_type == PACKET_TYPE_SYNC:
						_route_synchronization_packet(data_bytes, peer) # Route and Rebroadcast
					else:
						# Treat as chat/text message
						var message = data_bytes.get_string_from_utf8()
						print("HOST RECEIVED AND DECODED: ", message)
						
						# Process Message
						if message.begins_with("CHAT_MSG:"):
							var chat_content = message.trim_prefix("CHAT_MSG:")
							broadcast_tcp_message(peer, chat_content)
							emit_signal("chat_message_received", chat_content)
						else:
							send_tcp_message_as_host(peer, "TCP_ECHO: " + message)
				else:
					break
			else:
				break
				
	# UDP Poll
	if host_udp_server.is_listening():
		host_udp_server.poll()
		while host_udp_server.is_connection_available():
			var peer = host_udp_server.take_connection()
			while peer.get_available_packet_count() > 0:
				var packet = peer.get_packet()
				var received_string = packet.get_string_from_utf8()
				
				var ack_packet = "UDP Server ACK".to_utf8_buffer()
				peer.put_packet(ack_packet)
				
				emit_signal("server_status_update", "Received UDP data from client, sent ACK.")


func send_tcp_message_as_host(peer, message):
	var encoded_data = message.to_utf8_buffer()
	peer.put_u32(encoded_data.size())
	peer.put_data(encoded_data)

var is_initial_sync_complete : bool = false # Gate for sync packets

### NEW: Waits until a node path is registered in the scene tree ###
func _wait_for_node_by_path(node_path: String) -> Node:
	var target_node : Node = get_node_or_null(node_path)
	
	var attempts = 0
	# Wait loop: checks every frame for up to 600 frames (~10 seconds at 60 FPS)
	while not is_instance_valid(target_node) and attempts < 600:
		# Await one process frame: This yields control to the engine, allowing it to complete
		# its node registration process before we check again.
		await get_tree().process_frame
		target_node = get_node_or_null(node_path)
		attempts += 1
		
	return target_node

# CRITICAL CHANGE: poll_as_client MUST be async to use 'await'
func poll_as_client():
	# TCP Polling
	client_tcp_peer.poll()

	if client_tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		while client_tcp_peer.get_available_bytes() >= 4:
			var packet_length = client_tcp_peer.get_u32()

			if client_tcp_peer.get_available_bytes() >= packet_length:
				var data_result = client_tcp_peer.get_data(packet_length)
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					var packet_type = data_bytes[0]
					
					if packet_type == PACKET_TYPE_SYNC:
						# Gate: Only route sync data if initialization is complete
						if is_initial_sync_complete:
							_route_synchronization_packet(data_bytes) # Route locally
						else:
							push_warning("Client received sync packet before initialization. Dropping.")
					else:
						# Treat as text/chat message
						var received_string = data_bytes.get_string_from_utf8()
						print("CLIENT RECEIVED AND DECODED: ", received_string)
						
						if received_string.begins_with(NETID_ASSIGNMENT):
							# Handle NetID Assignment message (CRITICAL)
							var assignment_data = received_string.trim_prefix(NETID_ASSIGNMENT)
							var parts = assignment_data.split(":", false)
							
							if parts.size() == 2:
								var net_id = int(parts[0])
								var node_path = parts[1]
								
								# FIX: Wait ONLY until the node is available, then continue
								var target_node : Node = await _wait_for_node_by_path(node_path)
								
								if is_instance_valid(target_node) and target_node.has_node("Synchronizer"):
									var synchronizer_script = target_node.get_node("Synchronizer")
									
									# Set the local ID to match the Host's unique ID
									synchronizer_script.network_object_id = net_id
									# Register the ID in the client's map for future lookups
									net_id_to_synchronizer_map[net_id] = synchronizer_script
									
									# If we've assigned an ID, the gate can open
									is_initial_sync_complete = true 
									
									emit_signal("server_status_update", "NetID Assigned: %d for %s" % [net_id, node_path])
								else:
									push_warning("CLIENT: Node lookup failed even after waiting for path: " + node_path)
							else:
								push_warning("CLIENT: Malformed NETID_ASSIGNMENT message received.")
						
						elif received_string.begins_with("[CHAT]"):
							var chat_content = received_string.trim_prefix("[CHAT]").strip_edges()
							emit_signal("chat_message_received", chat_content)
						else:
							emit_signal("server_status_update", received_string)
				else:
					break
			else:
				break
	
	# UDP Polling
	while client_udp_peer.get_available_packet_count() > 0:
		var packet = client_udp_peer.get_packet()
		var received_string = packet.get_string_from_utf8()
		
		emit_signal("server_status_update", "UDP Reply: " + received_string)

# Added optional target_peer for directed synchronization
func send_synchronizers_in_tree(target_peer: StreamPeerTCP = null):
	var root : Node = get_tree().root
	send_synchronizers_in_children(root, target_peer)

# Added optional target_peer for directed synchronization
func send_synchronizers_in_children(parent : Node, target_peer: StreamPeerTCP = null):
	for child in parent.get_children():
		if child is Synchronizer:
			# NOTE: Synchronizer.gd's send() MUST accept 'target_peer'
			child.send(target_peer)
		send_synchronizers_in_children(child, target_peer)
