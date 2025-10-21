extends Control
class_name ServerClientSceneLoader

@export var server_scene : PackedScene
@export var client_scene : PackedScene


func _on_server_button_button_down() -> void:
	get_tree().change_scene_to_packed(server_scene)


func _on_client_button_button_down() -> void:
	get_tree().change_scene_to_packed(client_scene)
