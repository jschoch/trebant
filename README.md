Trabant
=======

** naive graph traversal for erlang and some backends like digraph dynamodb and mdigraph
 
* inspired by [gremlin](https://github.com/tinkerpop/gremlin) and [pacer](https://github.com/xnlogic/pacer)



```elixir
    
    # change the backend, this one uses mnesia
    Trabant.backend(Mdigraph)

    #populate the graph
    graph = Hel.createG

    # pull some maps from the graph
    [alcmene] = graph |> v_id(9) |> data
    [jupiter] = graph |> v_id(2) |> data
    [pluto] = graph |> v_id(10) |> data

  
    # get all neighbors with inbound edges
    # graph is a map with info about our stuff and traversal
    # v_id(id) fetches a vertex by ID and puts it into the stream
    ins = graph |> v_id(2) 
      # in is used in Elixir.Kernel so we use inn
      |> inn 
      # [data](https://github.com/jschoch/trebant/blob/master/lib/trabant.ex#L123-L126) is a shortcut for res(graph).data
      # it grabs graph.stream and process it
      |> data

    #  get the herculese map
    [herc] = graph |> v_id(2) |> inn(%{type: :demigod}) |> data
    assert herc.id == 5

```
