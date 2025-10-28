extends Node
class_name Synchronizer

@onready var parent : Node = $".."
@export var synch_transform : bool
@export var synch_properties : Array[String]

# This holds the unique, server-assigned integer ID (the NetID).
# We initialize it to -1, which is invalid, until the Server assigns a positive ID.
var network_object_id : int = -1 

func _ready() -> void:
	# Only the Host is allowed to assign unique Network IDs.
	if NetPeer.current_mode == NetPeer.NetMode.HOST:
		# Call the NetPeer singleton to assign a unique ID and register this instance.
		network_object_id = NetPeer.register_synchronizer(self)
	else:
		# The Client does nothing here. It waits for the Host to send a 
		# NETID_ASSIGNMENT message later to set the network_object_id.
		pass

# MODIFIED: Added optional 'target_peer' argument.
func send(target_peer: StreamPeerTCP = null):
	# Crucial check: Do not send if the object hasn't been assigned its unique ID yet.
	# (This is still the primary safety check for Clients)
	if network_object_id == -1: return

	var data_dic : Dictionary
	#------------ SYNCH TRANSFORM ----------#
	if synch_transform and parent.has_method("get_global_transform"):
		# Godot handles serializing Transform2D/3D to bytes automatically
		data_dic["global_transform"] = parent.global_transform
	
	#------------ SYNCH VARIABLES ----------#
	for property in synch_properties:
		
		var value = parent.get(property)
		data_dic[property] = value
	
	data_dic["_sender_id"] = NetPeer.local_client_id
	
	var binary_data : PackedByteArray = var_to_bytes(data_dic)
	
	# CRITICAL CHANGE: Pass the optional target_peer to the NetPeer's sending function.
	NetPeer.send_tcp_synchronization_data(binary_data, network_object_id, target_peer)


func receive(received_data: PackedByteArray):
	var received_dic: Dictionary = bytes_to_var(received_data)
	if typeof(received_dic) == TYPE_DICTIONARY:
		
		# --------------- RECEIVE TRANSFORM ---------------#
		if synch_transform and received_dic.has("global_transform") and parent.has_method("set_global_transform"):
			parent.global_transform = received_dic["global_transform"]
			# Remove it from the dictionary so it doesn't get processed in the loop below
			received_dic.erase("global_transform")
			print("Synched global_transform")
		
		# --------------- RECEIVE VARIABLES ---------------#
		for property in received_dic:
			if property in synch_properties:
				parent.set(property, received_dic[property])
				print("Synched property " + property)
			else:
				push_warning("Received property not in synch_properties: " + property)
		
	else:
		push_error("Failed to deserialize received data into a Dictionary.")
