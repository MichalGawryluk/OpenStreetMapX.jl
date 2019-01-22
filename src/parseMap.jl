#############################
### Parse Elements of Map ###
#############################

function parse_element(handler::LibExpat.XPStreamHandler,
                      name::AbstractString,
                      attr::Dict{AbstractString,AbstractString})
    data = handler.data::OpenStreetMapX.DataHandle
    if name == "node"
        data.element = :Tuple
        data.node = (parse(Int, attr["id"]),
                         OpenStreetMapX.LLA(parse(Float64,attr["lat"]), parse(Float64,attr["lon"])))
    elseif name == "way"
        data.element = :Way
        data.way = OpenStreetMapX.Way(parse(Int, attr["id"]))
    elseif name == "relation"
        data.element = :Relation
        data.relation = OpenStreetMapX.Relation(parse(Int, attr["id"]))
    elseif name == "bounds"
        data.element =:Bounds
        data.bounds = OpenStreetMapX.Bounds(parse(Float64,attr["minlat"]), parse(Float64,attr["maxlat"]), parse(Float64,attr["minlon"]), parse(Float64,attr["maxlon"]))
    elseif name == "tag"
        k = attr["k"]; v = attr["v"]
        if  data.element == :Tuple
			if haskey(FEATURE_CLASSES, k)
				data.osm.features[handler.data.node[1]] = k,v
			end
		elseif data.element == :Way
            data_tags = tags(data.way)
            push!(data.osm.way_tags, k)
			data_tags[k] = v
        elseif data.element == :Relation
            data_tags = tags(data.relation)
            push!(data.osm.relation_tags, k)
			data_tags[k] = v
        end
    elseif name == "nd"
        push!(data.way.nodes, parse(Int, attr["ref"]))
    elseif name == "member"
        push!(data.relation.members, attr)
    end
end

function collect_element(handler::LibExpat.XPStreamHandler, name::AbstractString)
    if name == "node"
        handler.data.osm.nodes[handler.data.node[1]] = handler.data.node[2]
        handler.data.element = :None
    elseif name == "way"
        push!(handler.data.osm.ways, handler.data.way)
        handler.data.element = :None
    elseif name == "relation"
        push!(handler.data.osm.relations, handler.data.relation)
        handler.data.element = :None
    elseif name == "bounds"
        handler.data.osm.bounds = handler.data.bounds
		handler.data.element = :None
    end
end

function parseOSM(filename::AbstractString; args...)::OpenStreetMapX.OSMData
    callbacks = LibExpat.XPCallbacks()
    callbacks.start_element = parse_element
    callbacks.end_element = collect_element
    data = OpenStreetMapX.DataHandle()
    LibExpat.parsefile(filename, callbacks, data=data; args...)
    data.osm 
end





"""
High level function - parses .osm file and create the road network based on the map data.
**Arguments**
* `datapath` : path with an .osm file
* `filename` : name of .osm file
* `road_levels` : a set with the road categories (see: OpenStreetMapX.ROAD_CLASSES for more informations)
* `use_cache` : a *.cache file will be crated with a serialized map image in the `datapath` folder
"""
function get_map_data(datapath::String,filename::String; road_levels::Set{Int} = Set(1:length(OpenStreetMapX.ROAD_CLASSES)),use_cache::Bool = true,only_intersections=true)::MapData
    #preprocessing map file
	cachefile = joinpath(datapath,filename*".cache")
	if use_cache && isfile(cachefile)
		f=open(cachefile,"r");
		res=Serialization.deserialize(f);
		close(f);
		@info "Read map data from cache $cachefile"
	else
		mapdata = OpenStreetMapX.parseOSM(joinpath(datapath,filename))
		OpenStreetMapX.crop!(mapdata,crop_relations = false)
		#preparing data
		bounds = mapdata.bounds
		nodes = OpenStreetMapX.ENU(mapdata.nodes,OpenStreetMapX.center(bounds))
		highways = OpenStreetMapX.filter_highways(OpenStreetMapX.extract_highways(mapdata.ways))
		roadways = OpenStreetMapX.filter_roadways(highways, levels= road_levels)
		intersections = OpenStreetMapX.find_intersections(roadways)
		segments = OpenStreetMapX.find_segments(nodes,roadways,intersections)
		
		#remove unuseful nodes
		roadways_nodes = unique(vcat(collect(way.nodes for way in roadways)...))
		nodes = Dict(key => nodes[key] for key in roadways_nodes)
	
		# e - Edges in graph, stored as a tuple (source,destination)
		# class - Road class of each edgey
		if only_intersections
			vals = Dict((segment.node0,segment.node1) => (segment.distance,segment.parent) for segment in segments)
			e = collect(keys(vals)) 
			vals = collect(values(vals))
			weights = map(val -> val[1],vals)
			class =  [classified_roadways[id] for id in map(val -> val[2],vals)]
		else 
			e,class = OpenStreetMapX.get_edges(nodes,roadways) 
			weights = OpenStreetMapX.distance(nodes,e)
		end
		# (node id) => (graph vertex)
		v = OpenStreetMapX.get_vertices(e)	
		edges = [v[id] for id in reinterpret(Int, e)]	
		I = edges[1:2:end]
		J = edges[2:2:end]    
		# w - Edge weights, indexed by graph id
		w = SparseArrays.sparse(I, J, weights, length(v), length(v))
		g = LightGraphs.DiGraph(w)	

		res = OpenStreetMapX.MapData(bounds,nodes,roadways,intersections,g,v,e,w,class)		
		if use_cache
			f=open(cachefile,"w");
			Serialization.serialize(f,res);
			@info "Saved map data to cache $cachefile"
			close(f);
		end
	end
    return res
end
