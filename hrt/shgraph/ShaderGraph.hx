package hrt.shgraph;

import hxsl.SharedShader;
using hxsl.Ast;
using hide.tools.Extensions.ArrayExtensions;
using haxe.EnumTools.EnumValueTools;
using Lambda;

typedef ShaderNodeDef = {
	expr: TExpr,
	inVars: Array<{v: TVar, internal: Bool, ?defVal: String}>, // If internal = true, don't show input in ui
	outVars: Array<{v: TVar, internal: Bool}>,
	externVars: Array<TVar>, // other external variables like globals and stuff
	inits: Array<{variable: TVar, value: Dynamic}>, // Default values for some variables
};

typedef Node = {
	x : Float,
	y : Float,
	id : Int,
	type : String,
	?properties : Dynamic,
	?instance : ShaderNode,
	?outputs: Array<Node>,
	?indegree : Int
};

private typedef Edge = {
	?outputNodeId : Int,
	nameOutput : String,
	?outputId : Int, // Fallback if name has changed
	?inputNodeId : Int,
	nameInput : String,
	?inputId : Int, // Fallback if name has changed
};

typedef Connection = {
	from : Node,
	fromName : String,
};

typedef Parameter = {
	name : String,
	type : Type,
	defaultValue : Dynamic,
	?id : Int,
	?variable : TVar,
	index : Int
};

enum Domain {
	Vertex;
	Fragment;
}

class ShaderGraph {

	var filepath : String;
	var graphs : Array<Graph>;


	public function new(filepath : String) {
		if (filepath == null) return;
		this.filepath = filepath;

		var json : Dynamic;
		try {
			var content : String = null;
			#if editor
			content = sys.io.File.getContent(hide.Ide.inst.resourceDir + "/" + this.filepath);
			#else
			content = hxd.res.Loader.currentInstance.load(this.filepath).toText();
			//content = hxd.Res.load(this.filepath).toText();
			#end
			if (content.length == 0) return;
			json = haxe.Json.parse(content);
		} catch( e : Dynamic ) {
			throw "Invalid shader graph parsing ("+e+")";
		}

		load(json);
	}

	public function load(json : Dynamic) : Void {

		graphs = [];

		parametersAvailable = [];
		parametersKeys = [];

		loadParameters(json.parameters ?? []);
		for (domain in haxe.EnumTools.getConstructors(Domain)) {
			var graph = new Graph(this, haxe.EnumTools.createByName(Domain, domain));
			var graphJson = Reflect.getProperty(json, domain);
			if (graphJson != null) {
				graph.load(graphJson);
			}

			graphs.push(graph);
		}
	}

	public function saveToDynamic() : Dynamic {
		var json : Dynamic = {};

		json.parameters = [
			for (p in parametersAvailable) { id : p.id, name : p.name, type : [p.type.getName(), p.type.getParameters().toString()], defaultValue : p.defaultValue, index : p.index }
		];

		for (graph in graphs) {
			var serName = EnumValueTools.getName(graph.domain);
			Reflect.setField(json, serName, graph.saveToDynamic());
		}

		return json;
	}

	public function saveToText() : String {
		return haxe.Json.stringify(saveToDynamic(), "\t");
	}

	public function compile2(?specificOutput: ShaderNode) : hrt.prefab.ContextShared.ShaderDef {
		var start = haxe.Timer.stamp();

		var gens : Array<ShaderNodeDef> = [];
		var inits : Array<{variable: TVar, value: Dynamic}>= [];

		var shaderData : ShaderData = {
			name: "",
			vars: [],
			funs: [],
		};


		for (i => graph in graphs) {
			var gen = graph.generate2(specificOutput);
			gens.push(gen);

			shaderData.vars.append(gen.externVars);
			for (v in gen.inVars)
				shaderData.vars.pushUnique(v.v);
			for (v in gen.outVars)
				shaderData.vars.pushUnique(v.v);

			var functionName : String = EnumValueTools.getName(graph.domain).toLowerCase();

			shaderData.funs.push({
				ret : TVoid, kind : Fragment,
				ref : {
					name : functionName,
					id : i,
					kind : Function,
					type : TFun([{ ret : TVoid, args : [] }])
				},
				expr : gen.expr,
				args : []
			});

			for (init in gen.inits) {
				inits.pushUnique(init);
			}
		}

		var shared = new SharedShader("");
		@:privateAccess shared.data = shaderData;
		@:privateAccess shared.initialize();

		var time = haxe.Timer.stamp() - start;
		trace("Shader compile2 in " + time * 1000 + " ms");

		return {shader : shared, inits: inits};
	}

	public function makeInstance(ctx: hrt.prefab.ContextShared) : hxsl.DynamicShader {
		var def = compile2();
		var s = new hxsl.DynamicShader(def.shader);
		for (init in def.inits)
			setParamValue(ctx, s, init.variable, init.value);
		return s;
	}

	static function setParamValue(ctx: hrt.prefab.ContextShared, shader : hxsl.DynamicShader, variable : hxsl.Ast.TVar, value : Dynamic) {
		try {
			switch (variable.type) {
				case TSampler2D:
					var t = ctx.loadTexture(value);
					t.wrap = Repeat;
					shader.setParamValue(variable, t);
				case TVec(size, _):
					shader.setParamValue(variable, h3d.Vector.fromArray(value));
				default:
					shader.setParamValue(variable, value);
			}
		} catch (e : Dynamic) {
			// The parameter is not used
		}
	}

	var allParameters = [];
	var current_param_id = 0;
	public var parametersAvailable : Map<Int, Parameter> = [];
	public var parametersKeys : Array<Int> = [];

	function generateParameter(name : String, type : Type) : TVar {
		return {
				parent: null,
				id: 0,
				kind:Param,
				name: name,
				type: type
			};
	}

	public function getParameter(id : Int) {
		return parametersAvailable.get(id);
	}

	public function addParameter(type : Type) {
		var name = "Param_" + current_param_id;
		parametersAvailable.set(current_param_id, {id: current_param_id, name : name, type : type, defaultValue : null, variable : generateParameter(name, type), index : parametersKeys.length});
		parametersKeys.push(current_param_id);
		current_param_id++;
		return current_param_id-1;
	}

	function loadParameters(parameters: Array<Dynamic>) {
		for (p in parameters) {
			var typeString : Array<Dynamic> = Reflect.field(p, "type");
			if (Std.isOfType(typeString, Array)) {
				if (typeString[1] == null || typeString[1].length == 0)
					p.type = std.Type.createEnum(Type, typeString[0]);
				else {
					var paramsEnum = typeString[1].split(",");
					p.type = std.Type.createEnum(Type, typeString[0], [Std.parseInt(paramsEnum[0]), std.Type.createEnum(VecType, paramsEnum[1])]);
				}
			}
			p.variable = generateParameter(p.name, p.type);
			this.parametersAvailable.set(p.id, p);
			parametersKeys.push(p.id);
			current_param_id = p.id + 1;
		}
		checkParameterOrder();
	}

	public function checkParameterOrder() {
		parametersKeys.sort((x,y) -> Reflect.compare(parametersAvailable.get(x).index, parametersAvailable.get(y).index));
	}


	public function setParameterTitle(id : Int, newName : String) {
		var p = parametersAvailable.get(id);
		if (p != null) {
			if (newName != null) {
				for (p in parametersAvailable) {
					if (p.name == newName) {
						return false;
					}
				}
				p.name = newName;
				p.variable = generateParameter(newName, p.type);
				return true;
			}
		}
		return false;
	}

	public function setParameterDefaultValue(id : Int, newDefaultValue : Dynamic) : Bool {
		var p = parametersAvailable.get(id);
		if (p != null) {
			if (newDefaultValue != null) {
				p.defaultValue = newDefaultValue;
				return true;
			}
		}
		return false;
	}

	public function removeParameter(id : Int) {
		parametersAvailable.remove(id);
		parametersKeys.remove(id);
		checkParameterIndex();
	}

	public function checkParameterIndex() {
		for (k in parametersKeys) {
			var oldParam = parametersAvailable.get(k);
			oldParam.index = parametersKeys.indexOf(k);
			parametersAvailable.set(k, oldParam);
		}
	}

	public function getGraph(domain: Domain) {
		return graphs[domain.getIndex()];
	}
}

class Graph {

	var allParamDefaultValue = [];
	var current_node_id = 0;
	var nodes : Map<Int, Node> = [];

	public var parent : ShaderGraph = null;

	public var domain : Domain = Fragment;


	public function new(parent: ShaderGraph, domain: Domain) {
		this.parent = parent;
		this.domain = domain;
	}

	public function load(json : Dynamic) {
		nodes = [];
		generate(Reflect.getProperty(json, "nodes"), Reflect.getProperty(json, "edges"));
	}

	public function generate(nodes : Array<Node>, edges : Array<Edge>) {
		for (n in nodes) {
			n.outputs = [];
			var cl = std.Type.resolveClass(n.type);
			if( cl == null ) throw "Missing shader node "+n.type;
			n.instance = std.Type.createInstance(cl, []);
			n.instance.setId(n.id);
			n.instance.loadProperties(n.properties);
			this.nodes.set(n.id, n);

			var shaderParam = Std.downcast(n.instance, ShaderParam);
			if (shaderParam != null) {
				var paramShader = getParameter(shaderParam.parameterId);
				shaderParam.variable = paramShader.variable;
				shaderParam.computeOutputs();
			}
		}
		if (nodes[nodes.length-1] != null)
			this.current_node_id = nodes[nodes.length-1].id+1;

		// Migration patch
		for (e in edges) {
			if (e.inputNodeId == null)
				e.inputNodeId = (e:Dynamic).idInput;
			if (e.outputNodeId == null)
				e.outputNodeId = (e:Dynamic).idOutput;
		}

		for (e in edges) {
			addEdge(e);
		}
	}

	public function addEdge(edge : Edge) {
		var node = this.nodes.get(edge.inputNodeId);
		var output = this.nodes.get(edge.outputNodeId);

		var inputs = node.instance.getInputs2(domain);
		var outputs = output.instance.getOutputs2(domain);

		var inputName = edge.nameInput;
		var outputName = edge.nameOutput;

		// Patch I/O if name have changed
		if (!outputs.exists(outputName)) {
			var def = output.instance.getShaderDef(domain);
			if(edge.outputId != null && def.outVars.length > edge.outputId) {
				outputName = def.outVars[edge.outputId].v.name;
			}
			else {
				return false;
			}
		}

		if (!inputs.exists(inputName)) {
			var def = node.instance.getShaderDef(domain);
			if (edge.inputId != null && def.inVars.length > edge.inputId) {
				inputName = def.inVars[edge.inputId].v.name;
			}
			else {
				return false;
			}
		}

		var connection : Connection = {from: output, fromName: outputName};
		node.instance.connections.set(inputName, connection);

		#if editor
		if (hasCycle()){
			removeEdge(edge.inputNodeId, inputName, false);
			return false;
		}

		var inputType = inputs[inputName].v.type;
		var outputType = outputs[outputName].type;

		if (!areTypesCompatible(inputType, outputType)) {
			removeEdge(edge.inputNodeId, inputName);
		}
		try {
		} catch (e : Dynamic) {
			removeEdge(edge.inputNodeId, inputName);
			throw e;
		}
		#end
		return true;
	}

	public function areTypesCompatible(input: hxsl.Ast.Type, output: hxsl.Ast.Type) : Bool {
		return switch (input) {
			case TFloat, TVec(_, VFloat):
				switch (output) {
					case TFloat, TVec(_, VFloat): true;
					default: false;
				}
			default: haxe.EnumTools.EnumValueTools.equals(input, output);
		}
	}

	public function removeEdge(idNode, nameInput, update = true) {
		var node = this.nodes.get(idNode);
		this.nodes.get(node.instance.connections[nameInput].from.id).outputs.remove(node);

		node.instance.connections.remove(nameInput);
	}

	public function setPosition(idNode : Int, x : Float, y : Float) {
		var node = this.nodes.get(idNode);
		node.x = x;
		node.y = y;
	}

	public function getNodes() {
		return this.nodes;
	}

	public function getNode(id : Int) {
		return this.nodes.get(id);
	}



	public function generate2(?specificOutput: ShaderNode) : ShaderNodeDef {

		var varIdCount = 0;
		var getNewVarId = function()
		{
			return varIdCount++;
		};

		inline function getNewVarName(node: Node, id: Int) : String {
			return '_sg_${(node.type).split(".").pop()}_var_$id';
		}

		var nodeOutputs : Map<Node, Map<String, TVar>> = [];
		function getOutputs(node: Node) : Map<String, TVar> {
			if (!nodeOutputs.exists(node)) {
				var outputs : Map<String, TVar> = [];

				var def = node.instance.getShaderDef(domain);
				for (output in def.outVars) {
					if (output.internal)
						continue;
					var type = output.v.type;
					if (type == null) throw "no type";
					var id = getNewVarId();
					var outVar = {id: id, name: getNewVarName(node, id), type: type, kind : Local};
					outputs.set(output.v.name, outVar);
				}

				nodeOutputs.set(node, outputs);
			}
			return nodeOutputs.get(node);
		}

		// Recursively replace the to tvar with from tvar in the given expression
		function replaceVar(expr: TExpr, what: TVar, with: TExpr) : TExpr {
			if(!what.type.equals(with.t))
				throw "type missmatch " + what.type + " != " + with.t;
			function repRec(f: TExpr) {
				if (f.e.equals(TVar(what))) {
					return with;
				} else {
					return f.map(repRec);
				}
			}
			var expr = repRec(expr);
			//trace("replaced " + what.getName() + " with " + switch(with.e) {case TVar(v): v.getName(); default: "err";});
			//trace(hxsl.Printer.toString(expr));
			return expr;
		}

		// Shader generation starts here

		var pos : Position = {file: "", min: 0, max: 0};
		var outputNodes : Array<Node> = [];
		var inits : Array<{ variable : hxsl.Ast.TVar, value : Dynamic }> = [];

		var allConnections : Array<Connection> = [for (node in nodes) for (connection in node.instance.connections) connection];


		// find all node with no output
		var nodeHasOutputs : Map<Node, Bool> = [];
		for (node in nodes) {
			nodeHasOutputs.set(node, false);
		}
		for (connection in allConnections) {
			nodeHasOutputs.set(connection.from, true);
		}

		var graphInputVars  = [];
		var graphOutputVars  = [];
		var externs : Array<TVar> = [];

		var nodeToExplore : Array<Node> = [];

		for (node => hasOutputs in nodeHasOutputs) {
			if (!hasOutputs)
				nodeToExplore.push(node);
		}

		var sortedNodes : Array<Node> = [];

		// Topological sort the nodes with Kahn's algorithm
		// https://en.wikipedia.org/wiki/Topological_sorting#Kahn's_algorithm
		{
			while (nodeToExplore.length > 0) {
				var currentNode = nodeToExplore.pop();
				sortedNodes.push(currentNode);
				for (connection in currentNode.instance.connections) {
					var targetNode = connection.from;
					if (!allConnections.remove(connection)) throw "connection not in graph";
					if (allConnections.find((n:Connection) -> n.from == targetNode) == null) {
						nodeToExplore.push(targetNode);
					}
				}
			}
		}

		function convertToType(targetType: hxsl.Ast.Type, sourceExpr: TExpr) : TExpr {
			var sourceType = sourceExpr.t;

			if (sourceType.equals(targetType))
				return sourceExpr;

			var sourceSize = switch (sourceType) {
				case TFloat: 1;
				case TVec(size, VFloat): size;
				default:
					throw "Unsupported source type " + sourceType;
			}

			var targetSize = switch (targetType) {
				case TFloat: 1;
				case TVec(size, VFloat): size;
				default:
					throw "Unsupported target type " + targetType;
			}

			var delta = targetSize - sourceSize;
			if (delta == 0)
				return sourceExpr;
			if (delta > 0) {
				var args = [];
				if (sourceSize == 1) {
					for (_ in 0...targetSize) {
						args.push(sourceExpr);
					}
				}
				else {
					args.push(sourceExpr);
					for (i in 0...delta) {
						args.push({e : TConst(CFloat(0.0)), p: sourceExpr.p, t: TFloat});
					}
				}
				var global : TGlobal = switch (targetSize) {
					case 2: Vec2;
					case 3: Vec3;
					case 4: Vec4;
					default: throw "unreachable";
				}
				return {e: TCall({e: TGlobal(global), p: sourceExpr.p, t:targetType}, args), p: sourceExpr.p, t: targetType};
			}
			if (delta < 0) {
				var swizz : Array<hxsl.Ast.Component> = [X,Y,Z,W];
				swizz.resize(targetSize);
				return {e: TSwiz(sourceExpr, swizz), p: sourceExpr.p, t: targetType};
			}
			throw "unreachable";
		}

		// Actually build the final shader expression
		var exprsReverse : Array<TExpr> = [];
		for (currentNode in sortedNodes) {

			// Skip nodes with no outputs that arent a final node
			if (!nodeHasOutputs.get(currentNode))
			{
				if (specificOutput != null && currentNode.instance != specificOutput)
					continue;
				if ( currentNode.instance != specificOutput && Std.downcast(currentNode.instance, ShaderOutput)==null) {
					continue;
				}
			}


			var outputs = getOutputs(currentNode);

			{
				var def = currentNode.instance.getShaderDef(domain);
				var expr = def.expr;

				var outputDecls : Array<TVar> = [];

				for (nodeVar in def.inVars) {
					var connection = currentNode.instance.connections.get(nodeVar.v.name);

					var replacement : TExpr = null;

					if (connection != null) {
						var outputs = getOutputs(connection.from);
						var outputVar = outputs[connection.fromName];
						if (outputVar == null) throw "null tvar";
						replacement = convertToType(nodeVar.v.type,  {e: TVar(outputVar), p:pos, t: outputVar.type});
					}
					else {
						var shParam = Std.downcast(currentNode.instance, ShaderParam);
						if (shParam != null) {
							var outVar = outputs["output"];
							var id = getNewVarId();
							outVar.id = id;
							outVar.name = nodeVar.v.name;
							outVar.type = nodeVar.v.type;
							outVar.kind = Param;
							outVar.qualifiers = [];
							graphInputVars.push({v: outVar, internal: false});
							var param = getParameter(shParam.parameterId);
							inits.push({variable: outVar, value: param.defaultValue});
							continue;
						}
						else {
							// default parameter if no connection
							var defVal = 0.0;
							var defaultValue = Reflect.getProperty(currentNode.instance.defaults, nodeVar.v.name);
							if (defaultValue != null) {
								defVal = Std.parseFloat(defaultValue) ?? 0.0;
							}
							replacement = convertToType(nodeVar.v.type, {e: TConst(CFloat(defVal)), p: pos, t:TFloat});
						}
					}

					expr = replaceVar(expr, nodeVar.v, replacement);
				}

				for (nodeVar in def.outVars) {
					var outputVar : TVar = outputs.get(nodeVar.v.name);
					// Kinda of a hack : skip decl writing for shaderParams
					var shParam = Std.downcast(currentNode.instance, ShaderParam);
					if (shParam != null) {
						continue;
					}
					if (outputVar == null) {
						graphOutputVars.push({v: nodeVar.v, internal: false});
					} else {
						expr = replaceVar(expr, nodeVar.v, {e: TVar(outputVar), p:pos, t: nodeVar.v.type});
						outputDecls.push(outputVar);
					}
				}

				for (nodeVar in def.externVars) {
					externs.pushUnique(nodeVar);
				}

				if (expr != null)
					exprsReverse.push(expr);

				for (output in outputDecls) {
					var finalExpr : TExpr = {e: TVarDecl(output), p: pos, t: output.type};
					exprsReverse.push(finalExpr);
				}
			}
		}

		exprsReverse.reverse();

		return {
			expr: {e: TBlock(exprsReverse), t:TVoid, p:pos},
			inVars: graphInputVars,
			outVars: graphOutputVars,
			externVars: externs,
			inits: inits,
		};
	}

	public function getParameter(id : Int) {
		return parent.getParameter(id);
	}


	#if editor
	public function addNode(x : Float, y : Float, nameClass : Class<ShaderNode>) {
		var node : Node = { x : x, y : y, id : current_node_id, type: std.Type.getClassName(nameClass) };

		node.instance = std.Type.createInstance(nameClass, []);
		node.instance.setId(current_node_id);
		node.instance.computeOutputs();
		node.outputs = [];

		this.nodes.set(node.id, node);
		current_node_id++;

		return node.instance;
	}

	public function hasCycle() : Bool {
		var queue : Array<Node> = [];

		var counter = 0;
		var nbNodes = 0;
		for (n in nodes) {
			n.indegree = n.outputs.length;
			if (n.indegree == 0) {
				queue.push(n);
			}
			nbNodes++;
		}

		var currentIndex = 0;
		while (currentIndex < queue.length) {
			var node = queue[currentIndex];
			currentIndex++;

			for (connection in node.instance.connections) {
				var nodeInput = connection.from;
				nodeInput.indegree -= 1;
				if (nodeInput.indegree == 0) {
					queue.push(nodeInput);
				}
			}
			counter++;
		}

		return counter != nbNodes;
	}

	public function removeNode(idNode : Int) {
		this.nodes.remove(idNode);
	}

	public function saveToDynamic() : Dynamic {
		var edgesJson : Array<Edge> = [];
		for (n in nodes) {
			for (inputName => connection in n.instance.connections) {
				var def = n.instance.getShaderDef(domain);
				var inputId = null;
				for (i => inVar in def.inVars) {
					if (inVar.v.name == inputName) {
						inputId = i;
						break;
					}
				}

				var def = connection.from.instance.getShaderDef(domain);
				var outputId = null;
				for (i => outVar in def.outVars) {
					if (outVar.v.name == connection.fromName) {
						outputId = i;
						break;
					}
				}

				edgesJson.push({ outputNodeId: connection.from.id, nameOutput: connection.fromName, inputNodeId: n.id, nameInput: inputName, inputId: inputId, outputId: outputId });
			}
		}
		var json = {
			nodes: [
				for (n in nodes) { x : Std.int(n.x), y : Std.int(n.y), id: n.id, type: n.type, properties : n.instance.saveProperties() }
			],
			edges: edgesJson
		};

		return json;
	}
	#end
}