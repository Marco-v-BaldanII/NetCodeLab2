extends CharacterBody2D
class_name Pokemon

@export var my_name : String
@export var level : int
@export var type : PokemonType
@onready var synchronizer: Synchronizer = $Synchronizer

const SPEED : int = 350

enum PokemonType{
	
	NORMAL,
	FIRE,
	WATER,
	GRASS,
	ELECTRIC
	
}

func _input(event: InputEvent) -> void:
	
	if synchronizer.does_own_node():
		var new_velocity : Vector2 = Vector2.ZERO
		velocity = new_velocity
		
		if Input.is_action_pressed("move_left"):
			new_velocity.x += -SPEED
		if Input.is_action_pressed("move_right"):
			new_velocity.x +=  SPEED
		if Input.is_action_pressed("move_up"):
			new_velocity.y += -SPEED
		if Input.is_action_pressed("move_down"):
			new_velocity.y +=  SPEED
		
		velocity = new_velocity
	

func _process(delta: float) -> void:
	move_and_slide()
