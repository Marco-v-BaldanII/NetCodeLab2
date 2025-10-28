extends Node
class_name Synchronizer

@onready var parent : Node = $".."
@export var synch_properties : Array[String]

var ID : int

func _ready() -> void:
	ID = parent.get_multiplayer_authority()

func send() :
	var data_dic : Dictionary
	
	for property in synch_properties:
		
		var value = parent.get(property)
		data_dic[property] = value
	data_dic["_sender_id"] = NetPeer.local_client_id
	
	var binary_data : PackedByteArray = var_to_bytes(data_dic)
	NetPeer.send_tcp_binary(binary_data, 0)


func receive(received_data: PackedByteArray):
	var received_dic: Dictionary = bytes_to_var(received_data)
	if typeof(received_dic) == TYPE_DICTIONARY:
		
		for property in received_dic:
			if property in synch_properties:
				parent.set(property, received_dic[property])
			else:
				
				push_warning("Received property not in synch_properties: " + property)
		
	else:
		push_error("Failed to deserialize received data into a Dictionary.")
