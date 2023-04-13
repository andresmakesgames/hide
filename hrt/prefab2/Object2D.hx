package hrt.prefab2;
import hxd.Math;

class Object2D extends Prefab {
	@:s @:range(0,400) public var x : Float = 0.;
	@:s @:range(0,400) public var y : Float = 0.;
	@:s public var scaleX : Float = 1.;
	@:s public var scaleY : Float = 1.;
	@:s public var rotation : Float = 0.;

	@:s public var visible : Bool = true;
	@:s public var blendMode : h2d.BlendMode = None;

	public var local2d : h2d.Object;

	public static function getLocal2d(prefab: Prefab) : h2d.Object {
		var obj2d = Std.downcast(prefab, Object2D);
		if (obj2d != null)
			return obj2d.local2d;
		return null;
	}

	/*function set_x(v : Float) {
		x = v;
		local2d.x = x;
		return x;
	}

	function set_y(v : Float) {
		y = v;
		local2d.y = y;
		return y;
	}*/

	function makeObject2d(parent2d: h2d.Object) : h2d.Object {
		return new h2d.Object(parent2d);
	}

	override function makeInstance() {
		local2d = makeObject2d(shared.tempInstanciateLocal2d);
		if (local2d != null)
			local2d.name = name;
		updateInstance();
	}


	public function loadTransform(t) {
		x = t.x;
		y = t.y;
		scaleX = t.scaleX;
		scaleY = t.scaleY;
		rotation = t.rotation;
	}

	public function saveTransform() {
		return { x : x, y : y, scaleX : scaleX, scaleY : scaleY, rotation : rotation };
	}

	public function setTransform(t) {
		x = t.x;
		y = t.y;
		scaleX = t.scaleX;
		scaleY = t.scaleY;
		rotation = t.rotation;
	}

	public function applyTransform( o : h2d.Object ) {
		o.x = x;
		o.y = y;
		o.scaleX = scaleX;
		o.scaleY = scaleY;
		o.rotation = Math.degToRad(rotation);
	}

	override function updateInstance(?propName : String ) {
		var o = local2d;
		o.x = x;
		o.y = y;
		if(propName == null || propName.indexOf("scale") == 0) {
			o.scaleX = scaleX;
			o.scaleY = scaleY;
		}
		if(propName == null || propName.indexOf("rotation") == 0)
			o.rotation = Math.degToRad(rotation);
		if(propName == null || propName == "visible")
			o.visible = visible;

		if(propName == null || propName == "blendMode")
			if (blendMode != null) o.blendMode = blendMode;
	}

	#if editor
	override function getHideProps() : hide.prefab2.HideProps {
		// Check children
		return {
			icon : children == null || children.length > 0 ? "folder-open" : "genderless",
			name : "Group 2D"
		};
	}

	override function edit( ctx : hide.prefab2.EditContext ) {
		var props = new hide.Element('
			<div class="group" name="Position">
				<dl>
					<dt>X</dt><dd><input type="range" min="-100" max="100" value="0" field="x"/></dd>
					<dt>Y</dt><dd><input type="range" min="-100" max="100" value="0" field="y"/></dd>
					<dt>Scale</dt><dd><input type="multi-range" min="0" max="5" value="0" field="scale" data-subfields="X,Y"/></dd>
					<dt>Rotation</dt><dd><input type="range" min="-180" max="180" value="0" field="rotation" /></dd>
				</dl>
			</div>
			<div class="group" name="Display">
				<dl>
					<dt>Visible</dt><dd><input type="checkbox" field="visible"/></dd>
					<dt>Blend Mode</dt><dd><select field="blendMode"/></dd></dd>
				</dl>
			</div>
		');
		ctx.properties.add(props, this, function(pname) {
			ctx.onChange(this, pname);
		});
	}

	#end

	override function getDefaultName() {
		return type == "object2D" ? "group2D" : super.getDefaultName();
	}

	static var _ = Prefab.register("object2D", Object2D);

}