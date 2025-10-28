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
const UDP_PORT = 5001 # Host listens here. Client uses unique port.

# --- SYNCHRONIZATION CONSTANTS ---
const PACKET_TYPE_SYNC = 0x01
const NETID_ASSIGNMENT = "NETID_ASSIGNMENT:"
const CLIENT_UDP_PORT_ASSIGNMENT = "CLIENT_UDP_PORT_ASSIGNMENT:" # NEW

var client_tcp_peer := StreamPeerTCP.new()
var client_udp_peer := PacketPeerUDP.new()

# Sockets and Lists used when current_mode is HOST
var host_tcp_server := TCPServer.new()
var host_udp_server := UDPServer.new()
var host_tcp_peers : Array = [] # List of StreamPeerTCPs
var client_udp_endpoints : Dictionary = {} # Maps client_id to {ip: String, port: int}

# --- HOST TRACKING ---
var next_client_id : int = 2
var host_peers_by_id : Dictionary = {} # Maps client_id -> StreamPeerTCP
var initialized_peers : Dictionary = {} # Maps StreamPeerTCP -> client_id (Used to find ID quickly for TCP cleanup/updates)

# --- SYNCHRONIZATION REGISTRY ---
var next_net_id : int = 100
var net_id_to_synchronizer_map : Dictionary = {}

# --- SYNCHRONIZATION UPDATE RATE ---
const SYNC_RATE_PER_SECOND = 10.0
var _sync_timer: float = 0.0

var local_client_id : int = -1 # 0 host, >=1 client
var is_initial_sync_complete : bool = false # Client-side gate for sync packets

# --- INITIALIZATION ---

func init_host():
	if current_mode != NetMode.DISCONNECTED: return
	current_mode = NetMode.HOST
	start_server()
	print("NetPeer initialized as HOST.")
	local_client_id = 0


func init_client(ip_address):
	if current_mode != NetMode.DISCONNECTED: return
	current_mode = NetMode.CLIENT
	
	# 🔴 FIX 1: Client MUST bind to port 0 to get a unique, available port.
	var udp_error = client_udp_peer.bind(0)
	if udp_error != OK:
		print("UDP Client failed to bind unique port (Error: %d). UDP sync will fail." % udp_error)
		
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

func send_synchronization_data(data: PackedByteArray, network_object_id: int, target_peer: StreamPeerTCP = null, protocol: Synchronizer.PROTOCOL = Synchronizer.PROTOCOL.UDP):
	
	var stream = StreamPeerBuffer.new()
	stream.put_u8(PACKET_TYPE_SYNC)
	stream.put_u32(network_object_id)
	stream.put_data(data)
	var final_payload = stream.data_array
	
	match current_mode:
		NetMode.HOST:
			if protocol == Synchronizer.PROTOCOL.TCP :
				if target_peer:
					_send_framed_data_to_peer(target_peer, final_payload)
				else:
					for peer in host_tcp_peers:
						if initialized_peers.has(peer):    
							_send_framed_data_to_peer(peer, final_payload)
			
			elif protocol == Synchronizer.PROTOCOL.UDP:
				# UDP: Unreliable, Unframed Broadcast
				var udp_sender = PacketPeerUDP.new()
				
				for client_id in client_udp_endpoints:
					var endpoint = client_udp_endpoints[client_id]
					
					# 1. Set the destination address for the outgoing packet
					udp_sender.set_dest_address(endpoint.ip, endpoint.port)
					
					# 2. Put the packet on the wire
					udp_sender.put_packet(final_payload)
					
		NetMode.CLIENT:
			if protocol == Synchronizer.PROTOCOL.TCP :
				_send_framed_data_to_peer(client_tcp_peer, final_payload)
			
			elif protocol == Synchronizer.PROTOCOL.UDP :
				client_udp_peer.put_packet(final_payload)

# Helper to send a raw binary packet with framing (used for TCP)
func _send_framed_data_to_peer(peer: StreamPeerTCP, data: PackedByteArray):
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_u32(data.size())
		peer.put_data(data)

func _route_synchronization_packet(data_bytes: PackedByteArray, sender_peer: StreamPeerTCP = null):
	var stream = StreamPeerBuffer.new()
	stream.data_array = data_bytes
	
	stream.get_u8() # Consume PACKET_TYPE_SYNC (1 byte)
	
	var network_id = stream.get_u32() # Consume Network ID (4 bytes)
	
	var remaining_size = stream.get_size() - stream.get_position()
	var sync_payload = stream.get_data(remaining_size)
	
	# Find corresponding synchronizer and receive data
	if net_id_to_synchronizer_map.has(network_id):
		var synchronizer_script : Synchronizer = net_id_to_synchronizer_map[network_id]
		
		if is_instance_valid(synchronizer_script):
			synchronizer_script.receive(sync_payload[1]) 
		else:
			net_id_to_synchronizer_map.erase(network_id)
			push_warning("SYNC: Invalid instance found for NetID %d" % network_id)
	else:
		push_warning("SYNC: Failed to find object with Network ID: " + str(network_id))

	# Host rebroadcast logic (Only for TCP packets received from clients)
	if current_mode == NetMode.HOST and sender_peer != null:
		# Rebroadcast the full packet to other clients
		for peer in host_tcp_peers:
			if peer != sender_peer:
				_send_framed_data_to_peer(peer, data_bytes) 

func send_tcp_message_as_client(message):
	if client_tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		var encoded_data = message.to_utf8_buffer()
		_send_framed_data_to_peer(client_tcp_peer, encoded_data)
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

# Updated _process: Manages the timer
func _process(delta):
	# 1. Update Polling
	if current_mode == NetMode.HOST:
		poll_as_host()
	elif current_mode == NetMode.CLIENT:
		poll_as_client()
		
	# 2. Handle Fixed-Rate Synchronization (HOST ONLY)
	if current_mode == NetMode.HOST:
		_sync_timer += delta
		if _sync_timer >= 1.0 / SYNC_RATE_PER_SECOND:
			_update_all_synchronizers()
			_sync_timer = 0.0

func poll_as_host():
	# 1. Accept New Connections
	if host_tcp_server.is_listening() and host_tcp_server.is_connection_available():
		var new_peer : StreamPeerTCP = host_tcp_server.take_connection()
		
		var assigned_id = next_client_id
		next_client_id += 1
		
		host_tcp_peers.append(new_peer)
		host_peers_by_id[assigned_id] = new_peer
		
		# Register the client's UDP endpoint with a placeholder port
		_register_client_udp_endpoint(assigned_id, new_peer) 
		
		print("New TCP Client connected! ID: %d, Total peers: %d" % [assigned_id, host_tcp_peers.size()])
		emit_signal("peer_connected", assigned_id)
		
		# Send initial peer ID assignment
		var initial_message : String = "SERVER_ID_ASSIGNMENT:%d" % assigned_id
		send_tcp_message_as_host(new_peer, initial_message)
		
		# --- Send all existing NetID assignments to the new client (CRITICAL) ---
		for net_id in net_id_to_synchronizer_map:
			var sync_node : Synchronizer = net_id_to_synchronizer_map[net_id]
			var sync_path = sync_node.parent.get_path()
			
			var message = "%s%d:%s" % [NETID_ASSIGNMENT, net_id, sync_path]
			send_tcp_message_as_host(new_peer, message)

		# --- Send the full synchronization snapshot ONLY to the new client ---
		send_synchronizers_in_tree(new_peer) # Directs sync to one peer

		# Store peer for quick lookup (used in TCP cleanup/UDP update)
		initialized_peers[new_peer] = assigned_id
		
		broadcast_tcp_message(new_peer, "Server_Godot_Online")
		
	# 2. TCP Polling from existing Clients
	for i in range(host_tcp_peers.size() - 1, -1, -1):
		var peer = host_tcp_peers[i]
		peer.poll()
		
		# Handle disconnection
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			var client_id = -1
			if initialized_peers.has(peer):
				client_id = initialized_peers[peer]
				initialized_peers.erase(peer)
				
			if host_peers_by_id.has(client_id):
				host_peers_by_id.erase(client_id)
				
			# Cleanup UDP endpoint dictionary as well
			if client_udp_endpoints.has(client_id):
				client_udp_endpoints.erase(client_id)
				
			host_tcp_peers.remove_at(i)
			print("TCP Client disconnected (ID: %d). Total peers: %d" % [client_id, host_tcp_peers.size()])
			emit_signal("peer_disconnected", client_id)
			continue

		while peer.get_available_bytes() >= 4:
			
			var packet_length = peer.get_u32()
			
			if peer.get_available_bytes() >= packet_length:
				var data_result = peer.get_data(packet_length)
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					var packet_type = data_bytes[0]
					
					if packet_type == PACKET_TYPE_SYNC:
						_route_synchronization_packet(data_bytes, peer) # Route and Rebroadcast (TCP sync)
					else:
						# Treat as chat/text message
						var message = data_bytes.get_string_from_utf8()
						
						# 🔴 FIX 3: Host receives client's unique UDP port
						if message.begins_with(CLIENT_UDP_PORT_ASSIGNMENT):
							var port_str = message.trim_prefix(CLIENT_UDP_PORT_ASSIGNMENT)
							var port_num = int(port_str)
							
							if initialized_peers.has(peer):
								var client_id = initialized_peers[peer]
								if client_udp_endpoints.has(client_id):
									client_udp_endpoints[client_id].port = port_num
									print("Host updated UDP port for client %d to %d" % [client_id, port_num])
						
						# Process other messages
						elif message.begins_with("CHAT_MSG:"):
							var chat_content = message.trim_prefix("CHAT_MSG:")
							broadcast_tcp_message(peer, chat_content)
							emit_signal("chat_message_received", chat_content)
						else:
							send_tcp_message_as_host(peer, "TCP_ECHO: " + message)
				else:
					break
			else:
				break
				
	# 3. UDP Poll (Handle unsolicited client UDP packets)
	if host_udp_server.is_listening():
		host_udp_server.poll()
		while host_udp_server.is_connection_available():
			var peer = host_udp_server.take_connection()
			while peer.get_available_packet_count() > 0:
				var packet = peer.get_packet()
				var packet_type = packet[0]
				
				if packet_type == PACKET_TYPE_SYNC:
					_route_synchronization_packet(packet)
				else:
					var received_string = packet.get_string_from_utf8()
					
					var ack_packet = "UDP Server ACK".to_utf8_buffer()
					peer.put_packet(ack_packet)
					
					emit_signal("server_status_update", "Received UDP data from client, sent ACK: " + received_string)

func send_tcp_message_as_host(peer, message):
	var encoded_data = message.to_utf8_buffer()
	_send_framed_data_to_peer(peer, encoded_data)

### NEW: Waits until a node path is registered in the scene tree ###
func _wait_for_node_by_path(node_path: String) -> Node:
	var target_node : Node = get_node_or_null(node_path)
	var attempts = 0
	
	while not is_instance_valid(target_node) and attempts < 600:
		await get_tree().process_frame
		target_node = get_node_or_null(node_path)
		attempts += 1
			
	return target_node

func poll_as_client():
	# 1. TCP Polling (Handles assignments, chat, and reliable sync)
	client_tcp_peer.poll()

	if client_tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		while client_tcp_peer.get_available_bytes() >= 4:
			var packet_length = client_tcp_peer.get_u32()

			if client_tcp_peer.get_available_bytes() >= packet_length:
				var data_result = client_tcp_peer.get_data(packet_length)
				
				if data_result[0] == OK:
					var data_bytes = data_result[1]
					
					#  Check if the data array is empty
					if data_bytes.size() == 0:
						push_warning("Received an empty TCP packet. Dropping.")
						continue 
						
					var packet_type = data_bytes[0]
					
					if packet_type == PACKET_TYPE_SYNC:
						if is_initial_sync_complete:
							_route_synchronization_packet(data_bytes)
						else:
							push_warning("Client received TCP sync packet before initialization. Dropping.")
					else:
						var received_string = data_bytes.get_string_from_utf8()
						
						if received_string.begins_with(NETID_ASSIGNMENT):
							var assignment_data = received_string.trim_prefix(NETID_ASSIGNMENT)
							var parts = assignment_data.split(":", false)
							
							if parts.size() == 2:
								var net_id = int(parts[0])
								var node_path = parts[1]
								
								var target_node : Node = await _wait_for_node_by_path(node_path)
								
								if is_instance_valid(target_node) and target_node.has_node("Synchronizer"):
									var synchronizer_script = target_node.get_node("Synchronizer")
									
									synchronizer_script.network_object_id = net_id
									net_id_to_synchronizer_map[net_id] = synchronizer_script
									
									if not is_initial_sync_complete:
										is_initial_sync_complete = true # Gate open on first successful assignment
										
										# 🔴 FIX 2: Send the client's unique UDP port to the Host
										var unique_udp_port = client_udp_peer.get_local_port()
										var port_message = CLIENT_UDP_PORT_ASSIGNMENT + str(unique_udp_port)
										send_tcp_message_as_client(port_message)
										print("Client sent unique UDP port %d to Host." % unique_udp_port)
										
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
	
	# 2. UDP Polling (Receives UDP sync and other UDP messages)
	while client_udp_peer.get_available_packet_count() > 0:
		var packet = client_udp_peer.get_packet()
		
		# ✅ FIX 2: Check if the UDP packet is empty before accessing index [0]
		if packet.size() == 0:
			push_warning("Received an empty UDP packet. Dropping.")
			continue
			
		var packet_type = packet[0]
		
		if packet_type == PACKET_TYPE_SYNC:
			if is_initial_sync_complete:
				_route_synchronization_packet(packet)
		else:
			var received_string = packet.get_string_from_utf8()
			emit_signal("server_status_update", "UDP Reply: " + received_string)


func _update_all_synchronizers():
	if current_mode != NetMode.HOST: return
	
	for net_id in net_id_to_synchronizer_map:
		var synchronizer : Synchronizer = net_id_to_synchronizer_map[net_id]
		if is_instance_valid(synchronizer):
			synchronizer.send()

func send_synchronizers_in_tree(target_peer: StreamPeerTCP = null):
	var root : Node = get_tree().root
	send_synchronizers_in_children(root, target_peer)

func send_synchronizers_in_children(parent : Node, target_peer: StreamPeerTCP = null):
	for child in parent.get_children():
		if child is Synchronizer:
			child.send(target_peer)
		send_synchronizers_in_children(child, target_peer)

# Function to capture the client's UDP endpoint
func _register_client_udp_endpoint(client_id: int, peer: StreamPeerTCP):
	var ip_address = peer.get_connected_host() 

	# 🔴 FIX 1 (Host): Force loopback IP for local testing reliability.
	ip_address = "127.0.0.1" 

	client_udp_endpoints[client_id] = {
		"ip": ip_address,	
		"port": UDP_PORT # Placeholder port until client sends its unique port
	}
	print("Host registering client ", client_id, " for UDP sync at ", ip_address, ":", UDP_PORT)
