package hrt.prefab;

class DynamicShader extends Shader {

	var shaderDef : hrt.prefab.ContextShared.ShaderDef;

	public function new(?parent) {
		super(parent);
		type = "shader";
		props = {};
	}

	override function save() {
		fixSourcePath();
		return super.save();
	}

	override function updateInstance(ctx: Context, ?propName) {
		var shader = Std.downcast(ctx.custom, hxsl.DynamicShader);
		if(shader == null || shaderDef == null)
			return;
		for(v in shaderDef.shader.data.vars) {
			if(v.kind != Param)
				continue;
			var val : Dynamic = Reflect.field(props, v.name);
			switch(v.type) {
				case TVec(_, VFloat):
					if(val != null)
						val = h3d.Vector.fromArray(val);
					else
						val = new h3d.Vector();
				case TSampler2D:
					if(val != null)
						val = ctx.loadTexture(val);
					var childNoise = getOpt(hrt.prefab.l2d.NoiseGenerator, v.name);
					if(childNoise != null)
						val = childNoise.toTexture();
				default:
			}
			if(val == null)
				continue;
			shader.setParamValue(v, val);
		}
	}

	override function getShaderDefinition(?ctx:Context):hxsl.SharedShader {
		if( shaderDef == null && ctx != null )
			loadShaderDef(ctx);
		return shaderDef == null ? null : shaderDef.shader;
	}

	override function makeShader( ?ctx:Context ) {
		if( getShaderDefinition(ctx) == null )
			return null;
		var shader = new hxsl.DynamicShader(shaderDef.shader);
		for( v in shaderDef.inits ) {
			#if !hscript
			throw "hscript required";
			#else
			shader.hscriptSet(v.variable.name, v.value);
			#end
		}
		var prev = ctx.custom;
		ctx.custom = shader;
		updateInstance(ctx);
		ctx.custom = prev;
		return shader;
	}

	override function makeInstance(ctx:Context):Context {
		if( source == null )
			return ctx;
		return super.makeInstance(ctx);
	}

	function fixSourcePath() {
		#if editor
		var ide = hide.Ide.inst;
		var shadersPath = ide.projectDir + "/src";  // TODO: serach in haxe.classPath?

		var path = source.split("\\").join("/");
		if( StringTools.startsWith(path.toLowerCase(), shadersPath.toLowerCase()+"/") ) {
			path = path.substr(shadersPath.length + 1);
		}
		source = path;
		#end
	}

	public function loadShaderDef(ctx: Context) {
		if(shaderDef == null) {
			fixSourcePath();
			var path = source;
			if(StringTools.endsWith(path, ".hx")) {
				path = path.substr(0, -3);
			}
			shaderDef = ctx.loadShader(path);
		}
		if(shaderDef == null)
			return;

		#if editor
		// TODO: Where to init prefab default values?
		for( v in shaderDef.inits ) {
			if(!Reflect.hasField(props, v.variable.name)) {
				Reflect.setField(props, v.variable.name, v.value);
			}
		}
		for(v in shaderDef.shader.data.vars) {
			if(v.kind != Param)
				continue;
			if(!Reflect.hasField(props, v.name)) {
				Reflect.setField(props, v.name, getDefault(v.type));
			}
		}
		#end
	}

	#if editor

	override function edit( ctx : EditContext ) {
		super.edit(ctx);

		loadShaderDef(ctx.rootContext);
		if(shaderDef == null)
			return;

		var group = new hide.Element('<div class="group" name="Shader"></div>');

		var props = [];
		for(v in shaderDef.shader.data.vars) {
			if(v.kind != Param)
				continue;
			var prop = makeShaderType(v);
			props.push({name: v.name, t: prop});
		}
		group.append(hide.comp.PropsEditor.makePropsList(props));

		ctx.properties.add(group,this.props, function(pname) {
			ctx.onChange(this, pname);
		});
	}

	function makeShaderType( v : hxsl.Ast.TVar ) : hrt.prefab.Props.PropType {
		var min : Null<Float> = null, max : Null<Float> = null;
		if( v.qualifiers != null )
			for( q in v.qualifiers )
				switch( q ) {
				case Range(rmin, rmax): min = rmin; max = rmax;
				default:
				}
		return switch( v.type ) {
		case TInt:
			PInt(min == null ? null : Std.int(min), max == null ? null : Std.int(max));
		case TFloat:
			PFloat(min != null ? min : 0.0, max != null ? max : 1.0);
		case TBool:
			PBool;
		case TSampler2D:
			PTexture;
		case TVec(n, VFloat):
			PVec(n);
		default:
			PUnsupported(hxsl.Ast.Tools.toString(v.type));
		}
	}
	override function getHideProps() : HideProps {
		return { icon : "cog", name : "Shader", fileSource : ["hx"], allowParent : function(p) return p.to(Object2D) != null || p.to(Object3D) != null || p.to(Material) != null  };
	}

	#end

	public static function evalConst( e : hxsl.Ast.TExpr ) : Dynamic {
		return switch( e.e ) {
		case TConst(c):
			switch( c ) {
			case CNull: null;
			case CBool(b): b;
			case CInt(i): i;
			case CFloat(f): f;
			case CString(s): s;
			}
		case TCall({ e : TGlobal(Vec2 | Vec3 | Vec4) }, args):
			var vals = [for( a in args ) evalConst(a)];
			if( vals.length == 1 )
				switch( e.t ) {
				case TVec(n, _):
					for( i in 0...n - 1 ) vals.push(vals[0]);
					return vals;
				default:
					throw "assert";
				}
			return vals;
		default:
			throw "Unhandled constant init " + hxsl.Printer.toString(e);
		}
	}

	public static function getDefault(type: hxsl.Ast.Type): Dynamic {
		switch(type) {
			case TBool:
				return false;
			case TInt:
				return 0;
			case TFloat:
				return 0.0;
			case TVec( size, VFloat ):
				return [for(i in 0...size) 0];
			default:
				return null;
		}
		return null;
	}

	static var _ = Library.register("shader", DynamicShader);
}