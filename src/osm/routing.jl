##############################
### Get Edges of the Graph ###
##############################

function getEdges(nodes::Dict{Int,T},highways::Vector{OpenStreetMap.Way}) where T<:Union{OpenStreetMap.ENU,OpenStreetMap.ECEF}
    onewayRoads = map(OpenStreetMap.oneway,highways)
    reverseRoads = map(OpenStreetMap.reverseWay,highways)
	classes = OpenStreetMap.classifyRoadways(highways)
    edges = Dict{Tuple{Int,Int},Int}()
    for i = 1:length(highways)
        for j = 2:length(highways[i].nodes)
            n0 = highways[i].nodes[j-1]
            n1 = highways[i].nodes[j]
            start = n0 * !reverseRoads[i] + n1 * reverseRoads[i]
            fin = n0 * reverseRoads[i] + n1 * !reverseRoads[i]
			edges[(start,fin)] = classes[highways[i].id]
            onewayRoads[i] || (edges[(fin,start)] = classes[highways[i].id])
        end
    end
	return collect(keys(edges)), collect(values(edges))
end

#################################
### Get Vertices of the Graph ###
#################################

function getVertices(edges::Array{Tuple{Int64,Int64},1})
    graphNodes = unique(reinterpret(Int, edges))
    vertices = Dict{Int,Int}(zip(graphNodes, 1:length(graphNodes)))
end

###################################
### Get Distances Between Edges ###
###################################

function getDistances(nodes::Dict{Int,T},edges::Array{Tuple{Int64,Int64},1}) where T<:Union{OpenStreetMap.ENU,OpenStreetMap.ECEF}
    distances = []
    for edge in edges
        dist = OpenStreetMap.distance(nodes[edge[2]],nodes[edge[1]])
        push!(distances,dist)
    end
    return distances
end

####################################################
###	For Each Feature Find the Nearest Graph Node ###
####################################################

function featuresToGraph(nodes::Dict{Int,T}, features::Dict{Int,Tuple{String,String}}, network::OpenStreetMap.Network) where T<:(Union{OpenStreetMap.ENU,OpenStreetMap.ECEF})
    features_to_nodes = Dict{Int,Int}()
    sizehint!(features_to_nodes,length(features))
    for (key,value) in features
        if !haskey(network.v,key)
            features_to_nodes[key] = OpenStreetMap.nearestNode(nodes,nodes[key],network)
        else
            features_to_nodes[key] = key
        end
    end
    return features_to_nodes 
end

############################
### Create Network Graph ###
############################

### Create Network with all nodes ###

function createGraph(nodes::Dict{Int,T},highways::Vector{OpenStreetMap.Way}) where T<:Union{OpenStreetMap.ENU,OpenStreetMap.ECEF}
    e,class = OpenStreetMap.getEdges(nodes,highways)
    v = OpenStreetMap.getVertices(e)
    weights = OpenStreetMap.getDistances(nodes,e)
    edges = [v[id] for id in reinterpret(Int, e)]
    I = edges[1:2:end] 
    J = edges[2:2:end] 
    w = SparseArrays.sparse(I, J, weights, length(v), length(v))
    OpenStreetMap.Network(LightGraphs.DiGraph(w),v,e,w,class)
end

### Create Network with Roads intersections only### 

function createGraph(segments::Vector{Segment}, intersections::Dict{Int,Set{Int}},classifiedHighways::Dict{Int,Int})
    vals = Dict((segment.node0,segment.node1) => (segment.distance,segment.parent) for segment in segments)
	e = collect(keys(vals))
	vals = collect(values(vals))
	weights = map(val -> val[1],vals)
	class =  [classifiedHighways[id] for id in map(val -> val[2],vals)]
	v = OpenStreetMap.getVertices(e)
    edges = [v[id] for id in reinterpret(Int, e)]
    I = edges[1:2:end] 
    J = edges[2:2:end] 
    w = SparseArrays.sparse(I, J, weights, length(v), length(v))
    OpenStreetMap.Network(LightGraphs.DiGraph(w),v,e,w,class)
end

#########################################
### Find Routes - Auxiliary Functions ###
#########################################

### Dijkstra's Algorithm ###
function dijkstra(network::OpenStreetMap.Network, w::SparseArrays.SparseMatrixCSC{Float64,Int64}, startVertex::Int)
    return LightGraphs.dijkstra_shortest_paths(network.g, startVertex, w)
end

### Transpose distances to times ###

function networkTravelTimes(network::OpenStreetMap.Network, class_speeds::Dict{Int,Int})
    @assert length(network.e) == length(network.w.nzval)
    indices = [(network.v[i],network.v[j]) for (i,j) in network.e]
    w = Array{Float64}(length(network.e))
    for i = 1:length(w)
        w[i] = 3.6 * (network.w[indices[i]]/class_speeds[network.class[i]])
    end
    return w
end

### Create a Sparse Matrix for a given vector of weights ###

function createWeightsMatrix(network::OpenStreetMap.Network,weights::Vector{Float64})
    return SparseArrays.sparse(map(i -> network.v[i[1]], network.e), map(i -> network.v[i[2]], network.e),weights)
end

### Extract route from Dijkstra results object ###

function extractRoute(dijkstra::LightGraphs.DijkstraState{Float64,Int64}, startIndex::Int, finishIndex::Int)
    route = Int[]
    distance = dijkstra.dists[finishIndex]
    if distance != Inf
        index = finishIndex
        push!(route, index)
        while index != startIndex
            index = dijkstra.parents[index]
            push!(route, index)
        end
    end
    reverse!(route)
    return route, distance
end

### Extract nodes ID's from route object ###

function getRouteNodes(network::OpenStreetMap.Network, routeIndices::Array{Int64,1})
    routeNodes = Array{Int}(length(routeIndices))
    v = map(reverse, network.v)
    for n = 1:length(routeNodes)
        routeNodes[n] = v[routeIndices[n]]
    end
    return routeNodes
end

### Generate an ordered list of edges traversed in route ###

function routeEdges(network::OpenStreetMap.Network, routeNodes::Vector{Int})
	e = Array{Int}(length(routeNodes)-1)
	for i = 2:length(routeNodes)
		e[i-1] = findfirst(network.e, (routeNodes[i-1], routeNodes[i]))
	end
	return e
end

### Calculate distance with a given weights ###

calculateDistance(network::OpenStreetMap.Network, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, routeIndices::Array{Int64,1}) = sum(weights[(routeIndices[i-1], routeIndices[i])] for i = 2:length(routeIndices))


#####################################
### Find Route with Given Weights ###
#####################################

function findRoute(network::OpenStreetMap.Network, node0::Int, node1::Int, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, getDistance::Bool = false, getTime::Bool = false)
    result = Any[]
    startVertex = network.v[node0]
    dijkstraResult = OpenStreetMap.dijkstra(network, weights, startVertex)
    finishVertex= network.v[node1]
    routeIndices, routeValues = OpenStreetMap.extractRoute(dijkstraResult, startVertex, finishVertex)
    routeNodes = OpenStreetMap.getRouteNodes(network, routeIndices)
    push!(result, routeNodes, routeValues)
    if getDistance
		if isempty(routeIndices)
			distance = Inf
		elseif length(routeIndices) == 1
			distance = 0 
		else
			distance = OpenStreetMap.calculateDistance(network, network.w, routeIndices)
		end
        push!(result, distance)
    end
    if getTime
        w = OpenStreetMap.createWeightsMatrix(network,networkTravelTimes(network, SPEED_ROADS_URBAN))
		if isempty(routeIndices)
			routeTime = Inf
		elseif length(routeIndices) == 1
			routeTime = 0
        else
			routeTime = OpenStreetMap.calculateDistance(network, w, routeIndices)
		end
        push!(result, routeTime)
    end
    return result
end


#########################################################
### Find Route Connecting 3 Points with Given Weights ###
#########################################################

function findRoute(network::OpenStreetMap.Network, node0::Int, node1::Int, node2::Int, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, getDistance::Bool = false, getTime::Bool = false)
	result = Any[]
	route1 = OpenStreetMap.findRoute(network, node0, node1, weights, getDistance, getTime)
	route2 = OpenStreetMap.findRoute(network, node1, node2, weights, getDistance, getTime)
	push!(result,vcat(route1[1],route2[1]))
	for i = 2:length(route1)
		push!(result,route1[i] + route2[i])
	end
	return result
end

###########################
### Find Shortest Route ###
###########################

function shortestRoute(network::OpenStreetMap.Network, node0::Int, node1::Int)
	routeNodes, distance, routeTime = OpenStreetMap.findRoute(network,node0,node1,network.w,false,true)
	return routeNodes, distance, routeTime
end

##################################################################
### Find Shortest Route Connecting 3 Points with Given Weights ###
##################################################################

function shortestRoute(network::OpenStreetMap.Network, node0::Int, node1::Int, node2::Int)
	routeNodes, distance, routeTime = OpenStreetMap.findRoute(network,node0,node1, node2, network.w,false,true)
	return routeNodes, distance, routeTime
end

##########################
### Find Fastest Route ###
##########################

function fastestRoute(network::OpenStreetMap.Network, node0::Int, node1::Int, classSpeeds=OpenStreetMap.SPEED_ROADS_URBAN)
	w = OpenStreetMap.createWeightsMatrix(network,networkTravelTimes(network, classSpeeds))
	routeNodes, routeTime, distance = OpenStreetMap.findRoute(network,node0,node1,w,true, false)
	return routeNodes, distance, routeTime
end

#################################################################
### Find Fastest Route Connecting 3 Points with Given Weights ###
#################################################################

function fastestRoute(network::OpenStreetMap.Network, node0::Int, node1::Int, node2::Int, classSpeeds=OpenStreetMap.SPEED_ROADS_URBAN)
	w = OpenStreetMap.createWeightsMatrix(network,networkTravelTimes(network, classSpeeds))
	routeNodes, routeTime, distance = OpenStreetMap.findRoute(network,node0,node1, node2, w,true, false)
	return routeNodes, distance, routeTime
end

###########################################
### Find  waypoint minimizing the route ###
###########################################

### Approximate solution ###

function findOptimalWaypointApprox(network::OpenStreetMap.Network, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, node0::Int, node1::Int, waypoints::Dict{Int,Int})
    dists_start_waypoint = LightGraphs.dijkstra_shortest_paths(network.g, network.v[node0], weights).dists
    dists_waypoint_fin = LightGraphs.dijkstra_shortest_paths(network.g, network.v[node1], weights).dists
    node_id = NaN
    min_dist = Inf
    for (key,value) in waypoints
        dist  = dists_start_waypoint[network.v[value]] + dists_waypoint_fin[network.v[value]] 
        if dist < min_dist
            min_dist = dist
            node_id = value
        end
    end
    return node_id
end

### Exact solution ###

function findOptimalWaypointExact(network::OpenStreetMap.Network, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, node0::Int, node1::Int, waypoints::Dict{Int,Int})
    dists_start_waypoint = LightGraphs.dijkstra_shortest_paths(network.g, network.v[node0], weights).dists
    node_id = NaN
    min_dist = Inf
    for (key,value) in waypoints
        dist_to_fin = LightGraphs.dijkstra_shortest_paths(network.g, network.v[value], weights).dists[network.v[node1]]
        dist  = dists_start_waypoint[network.v[value]] + dist_to_fin
        if dist < min_dist
            min_dist = dist
            node_id = value
        end
    end
    return node_id
end

########################################################################
### Find Nodes Within Driving Time or Distance - Auxiliary Functions ###
########################################################################

### Bellman Ford's Algorithm ###
function bellmanFord(network::OpenStreetMap.Network, w::SparseArrays.SparseMatrixCSC{Float64,Int64}, startVertices::Vector{Int})
    return LightGraphs.bellman_ford_shortest_paths(network.g, startVertices, w)
end

### Filter vertices from BellmanFordStates object ###

function filterVertices(vertices::Dict{Int,Int}, weights::Vector{Float64}, limit::Float64)
    if limit == Inf
        @assert length(vertices) == length(weights)
        return keys(vertices), weights
    end
    indices = Int[]
    distances = Float64[]
    for vertex in keys(vertices)
        distance = weights[vertices[vertex]]
        if distance < limit
            push!(indices, vertex)
            push!(distances, distance)
        end
    end
    return indices, distances
end

##############################################################################
### Extract Nodes from BellmanFordStates Object Within an (Optional) Limit ###
### Based on Weights													   ###
##############################################################################

function nodesWithinWeights(network::OpenStreetMap.Network, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, startIndices::Vector{Int}, limit::Float64=Inf)
	startVertices = [network.v[i] for i in startIndices]
    bellmanford = OpenStreetMap.bellmanFord(network, weights, startVertices)
    return OpenStreetMap.filterVertices(network.v, bellmanford.dists, limit)
end

nodesWithinWeights(nodes::Dict{Int,T}, network::OpenStreetMap.Network, weights::SparseArrays.SparseMatrixCSC{Float64,Int64}, loc::T, limit::Float64=Inf,locRange::Float64=500.0) where T<:(Union{OpenStreetMap.ENU,OpenStreetMap.ECEF}) = OpenStreetMap.nodesWithinWeights(network, weights, nodesWithinRange(nodes, loc, network, locRange), limit)

##############################################################################
### Extract Nodes from BellmanFordStates Object Within an (Optional) Limit ###
### Based on Driving Distance											   ###
##############################################################################

function nodesWithinDrivingDistance(network::OpenStreetMap.Network, startIndices::Vector{Int}, limit::Float64=Inf)
    startVertices = [network.v[i] for i in startIndices]
    bellmanford = OpenStreetMap.bellmanFord(network, network.w, startVertices)
    return OpenStreetMap.filterVertices(network.v, bellmanford.dists, limit)
end

nodesWithinDrivingDistance(nodes::Dict{Int,T}, network::OpenStreetMap.Network, loc::T, limit::Float64=Inf,locRange::Float64=500.0) where T<:(Union{OpenStreetMap.ENU,OpenStreetMap.ECEF})= OpenStreetMap.nodesWithinDrivingDistance(network, nodesWithinRange(nodes, loc ,network, locRange), limit)

##############################################################################
### Extract Nodes from BellmanFordStates Object Within an (Optional) Limit ###
### Based on Driving Time												   ###
##############################################################################

function nodesWithinDrivingTime(network::OpenStreetMap.Network, startIndices::Vector{Int}, limit::Float64=Inf, classSpeeds::Dict{Int,Int}=OpenStreetMap.SPEED_ROADS_URBAN)
	w = OpenStreetMap.createWeightsMatrix(network,networkTravelTimes(network, classSpeeds))
	startVertices = [network.v[i] for i in startIndices]
    bellmanford = OpenStreetMap.bellmanFord(network, w, startVertices)
    return OpenStreetMap.filterVertices(network.v, bellmanford.dists, limit)
end

function nodesWithinDrivingTime(nodes::Dict{Int,T}, network::OpenStreetMap.Network, loc::T, limit::Float64=Inf, locRange::Float64=500.0, classSpeeds::Dict{Int,Int}=OpenStreetMap.SPEED_ROADS_URBAN) where T<:(Union{OpenStreetMap.ENU,OpenStreetMap.ECEF})
	w = OpenStreetMap.createWeightsMatrix(network,networkTravelTimes(network, classSpeeds))
	return OpenStreetMap.nodesWithinDrivingTime(network,nodesWithinRange(nodes, loc, network,locRange),limit,classSpeeds)
end
