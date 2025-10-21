extends Control
class_name OnlineMenu

func _ready():
	
	$CenterContainer/VBoxContainer/ServerButton.pressed.connect(self._on_create_game_button_pressed)
	$CenterContainer/VBoxContainer/ClientButton.pressed.connect(self._on_join_game_button_pressed)

func _on_create_game_button_pressed():
	NetPeer.init_host()
	get_tree().change_scene_to_file("res://Scenes/WaitingRoom.tscn")
	
func _on_join_game_button_pressed():
	var ip_address = "127.0.0.1"
	
	NetPeer.init_client(ip_address)
	get_tree().change_scene_to_file("res://Scenes/WaitingRoom.tscn")
