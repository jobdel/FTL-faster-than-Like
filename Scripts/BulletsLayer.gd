## BulletsLayer.gd
## Attach to the BulletsLayer Node2D inside the SubViewport.
## Registers this node with BulletManager so it knows where to parent the pool.
extends Node2D

func _ready() -> void:
	BulletManager.setup(self)
