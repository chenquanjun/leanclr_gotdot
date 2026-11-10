extends Node

func _ready() -> void:
	var runtime := LeanCLRRuntime.new()
	var bcl_dir := ProjectSettings.globalize_path("res://bin/bcl")
	var assembly_dir := ProjectSettings.globalize_path("res://bin/assemblies")
	if not runtime.initialize(PackedStringArray([bcl_dir, assembly_dir])):
		push_error("LeanCLR initialize failed: " + runtime.get_last_error())
		return
	if not runtime.load_assembly("LeanClrGame"):
		push_error("LeanCLR load_assembly failed: " + runtime.get_last_error())
		return

	var handle := runtime.create_object("PlayerController")
	if handle == 0:
		push_error("LeanCLR create_object failed: " + runtime.get_last_error())
		return
	print("PlayerController::Add(2, 3) = ", runtime.invoke_method(handle, "Add", [2, 3]))
	print("PlayerController::Describe() = ", runtime.invoke_method(handle, "Describe", []))
	print("get score = ", runtime.get_field(handle, "score"))
	runtime.set_field(handle, "score", 42)
	print("get score after set = ", runtime.get_field(handle, "score"))
	print("get title = ", runtime.get_field(handle, "title"))
	print("enum mode = ", runtime.get_field(handle, "mode"))
	print("struct data = ", runtime.get_field(handle, "data"))
	runtime.set_field(handle, "data", PackedByteArray([9, 0, 0, 0, 8, 0, 0, 0]))
	print("struct data after set = ", runtime.get_field(handle, "data"))
	print("data x = ", runtime.invoke_method(handle, "GetDataX", []))
	print("data y = ", runtime.invoke_method(handle, "GetDataY", []))
	var item_handle = runtime.get_field(handle, "item")
	print("item handle = ", item_handle)
	print("item value = ", runtime.get_field(item_handle, "value"))
	print("item describe = ", runtime.invoke_method(item_handle, "Describe", []))
	print("numbers sum = ", runtime.invoke_method(handle, "GetNumbersSum", []))
	var returned_item = runtime.invoke_method(handle, "GetItem", [])
	print("returned item reuses handle = ", returned_item == item_handle)
	print("returned item value = ", runtime.get_field(returned_item, "value"))
	var returned_numbers = runtime.invoke_method(handle, "GetNumbers", [])
	print("returned numbers is handle = ", returned_numbers is int)
	print("returned null item = ", runtime.invoke_method(handle, "GetNullItem", []) == null)
	print("describe passed item = ", runtime.invoke_method(handle, "DescribeItem", [item_handle]))
	print("sum passed numbers = ", runtime.invoke_method(handle, "SumNumbers", [returned_numbers]))
	print("describe passed null = ", runtime.invoke_method(handle, "DescribeItem", [null]))
	var spare_handle = runtime.get_field(handle, "spare")
	runtime.set_field(handle, "item", spare_handle)
	print("item reused handle = ", runtime.get_field(handle, "item") == spare_handle)
	print("item value after set = ", runtime.invoke_method(handle, "GetItemValue", []))
	runtime.set_field(handle, "item", null)
	print("item cleared = ", runtime.get_field(handle, "item") == null)
	print("item value after clear = ", runtime.invoke_method(handle, "GetItemValue", []))
	runtime.set_field(handle, "numbers", null)
	print("numbers sum after clear = ", runtime.invoke_method(handle, "GetNumbersSum", []))
	runtime.destroy_object(handle)

	var marker := Node2D.new()
	marker.name = "Marker"
	add_child(marker)

	var player := LeanCLRNode.new()
	player.managed_type = "PlayerController"
	player.managed_assembly = "LeanClrGame"
	player.runtime = runtime
	add_child(player)
	player.call_managed("SetTargetId", [marker.get_instance_id()])
	player.call_managed("TestNodeApi", [])
	player.call_managed("TestSceneApi", [])
	player.call_managed("TestResourceApi", [])
	print("call_managed(Add) = ", player.call_managed("Add", [4, 5]))
	print("get_managed_property(score) = ", player.get_managed_property("score"))
	player.set_managed_property("score", 99)
	print("get_managed_property(score) after set = ", player.get_managed_property("score"))
	player.bind_signal("leanclr_signal", "OnSignal")
	player.emit_leanclr_signal()
	player.call_managed("EmitTestSignal", [])
	player.bind_signal_args("leanclr_signal_args", "OnSignalArgs", 1)
	player.bind_signal_args("leanclr_signal_args2", "OnSignalArgs2", 2)
	player.emit_leanclr_signal_args("hello-args")
	player.emit_leanclr_signal_args2("hello-args2", 7)
	await get_tree().process_frame
	await get_tree().process_frame
	print("physics ticks = ", player.call_managed("GetPhysicsTicks", []))
	player.queue_free()
	await get_tree().process_frame
	runtime.shutdown()