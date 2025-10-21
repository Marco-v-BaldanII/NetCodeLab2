extends Control
class_name Chat

@onready var line_edit: LineEdit = $VBoxContainer/HBoxContainer/LineEdit
@onready var chat : TextEdit = $VBoxContainer/TextEdit


func _on_send_button_button_down() -> void:
	
	NetPeer.send_chat_message(line_edit.text)

func _ready() -> void:
	NetPeer.chat_message_received.connect(append_message_to_chat)

func append_message_to_chat(message : String):
	chat.text += "\n" + message

func scroll_chat_down():
	var scroll_bar = chat.get_v_scroll_bar()
	if scroll_bar:
		scroll_bar.value = scroll_bar.max_value
