if !@isdefined map_data
	include("map_snippet_plot.jl")
	mapfile = "map.osm";
	datapath = "../datasets/";
	map_data = OpenStreetMap2.get_map_data(datapath, mapfile);
end



for i in 1:1
    origin = generate_point_in_bounds(map_data);
    destination = generate_point_in_bounds(map_data);
    waypoint = generate_point_in_bounds(map_data);
    global r = find_routes(origin,waypoint,destination, map_data, true, (@isdefined r) ? (r.p) : (:none),width=400,height=350)
end

display(r.p)
