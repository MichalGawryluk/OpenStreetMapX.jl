using Test, OpenStreetMapX
import LightGraphs

@testset "maps" begin

m = get_map_data("data/reno_east3.osm",use_cache=false);


@test length(m.nodes) == 9032

using Random
Random.seed!(0);
pA = generate_point_in_bounds(m)
@test all(isapprox.(pA,(39.53584630184622, -119.71506095062803)))
pB = generate_point_in_bounds(m)
@test all(isapprox.(pB,(39.507242155639005, -119.78506509516248)))
pointA = point_to_nodes(pA, m)
pointB = point_to_nodes(pB, m)

@test pointA == 3052967037
@test pointB == 140393352


sr1, shortest_distance1, shortest_time1 = shortest_route(m, pointA, pointB)
@test (sr1[1], sr1[end]) == (pointA, pointB)

end;
