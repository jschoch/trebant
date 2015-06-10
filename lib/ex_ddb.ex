defmodule Ddb.V do
  @derive [ExAws.Dynamo.Encodable]
  #defstruct [:id,:r, :created_at]
  defstruct id: nil, r: "0", created_at: Timex.Time.now(:secs),v_type: nil
end
defmodule Ddb.E do
  @derive [ExAws.Dynamo.Encodable]
  defstruct id: nil, r: nil, label: nil,created_at: Timex.Time.now(:secs),target_id: nil,e_type: nil

  # convert label values to existing atoms
  defimpl ExAws.Dynamo.Decodable do
    def decode(%{label: label} = map) do
      %{map | label: String.to_existing_atom(label)}
    end
  end
end
defmodule Ddb.N do
  @derive [ExAws.Dynamo.Encodable]
  #defstruct [:id,:r, :created_at]
  defstruct id: nil, r: nil, created_at: Timex.Time.now(:secs),nbr_type: nil
end
defmodule Ddb do
  @behaviour Trabant.B
  #t_name() "Graph-#{Mix.env}"
  alias ExAws.Dynamo
  require Logger
  def t_name() do
    "Graph-#{Mix.env}"
  end
  def graph do
    %Trabant.G{g: %{table_name: t_name(), hash_key_name: "id",range_key_name: "r"}}
  end
  def new() do
    tbl = Dynamo.create_table(t_name(),[id: :hash,r: :range],[id: :string,r: :string], 25, 25)
    #tbl = Dynamo.create_table(t_name(),[id: :hash],[id: :string], 1, 1)
    Logger.debug inspect tbl
    %Trabant.G{g: %{table_name: t_name(), hash_key_name: "id",range_key_name: "r"}}
  end
  def new(string) do
    Logger.warn "use t_name(), this will ignore arg string: #{string} for new"
    new
  end
  def delete_graph() do
    Logger.warn "deleting table #{t_name()}"
    Dynamo.delete_table(t_name())
  end
  def all(graph,raw \\false) do
    case raw do
      false ->
        {:ok, stuff} = Dynamo.scan(t_name())
        {:unf, stuff}
        #Dynamo.Decoder.decode(stuff["Items"])
      true -> 
        Dynamo.stream_scan(t_name()) 
          |> Enum.map(&Dynamo.Decoder.decode(&1))
        #Dynamo.Decoder.decode(stuff["Items"])
    end
  end
  def test_id(id) when is_binary(id) do
    Logger.debug "testing id: #{id}"
    case byte_size(id) == 33 do
      false -> raise "need 33 byte binary for id, consider using create_string_id\n\tid: #{id}"
      true -> nil
    end
  end
  def test_id(id) do
    raise "can't create id, only supporting 33 byte strings right now" 
  end
  @doc "creates a vertex, id is optional, graph is derived from graph()"
  def create_v(map,label) when is_map(map) and is_atom(label) do
    graph = graph
    case Map.has_key?(map,:id) do
      true -> nil
      false -> 
        id = create_string_id(:node)
        map = Map.put(map,:id,id)
    end
    create_v(graph,map,label)
  end
  def create_v(graph,term,label \\[])
  def create_v(graph,%{id: id}, label) when is_number(id) do
    raise "can't use integer id's until we workout how to get the table creation types aligned and correct"
  end
  def create_v(graph,%{id: id, r: r} = term,label) when is_binary(id) do
    test_id(id)
    vertex = %Ddb.V{} |> Map.merge(term)
    vertex = Map.put(vertex,:v_type,:node)
    res = Dynamo.put_item(t_name(),vertex)
    vertex
  end
  @doc "another hack for range key"
  def create_v(graph,%{id: id} = term,label) when is_binary(id) do
    test_id(id)
    r = "0"
    vertex = %Ddb.V{r: r} |> Map.merge(term)
    create_v(graph,vertex)
  end

  def add_out_edge(graph,aid,bid,label,term) when is_binary(aid) and is_binary(bid) do
    ie_id = cast_id(bid,:in_edge)
    ie_r = aid <> Atom.to_string(label)
    oe_map = %{
      id: cast_id(aid,:out_edge),
      map: term,
      label: label,
      target_id: ie_id,
      e_type: :out,
      r: bid <> Atom.to_string(label)
    }
    out_edge = Map.merge(%Ddb.E{},oe_map)
    {:ok,%{}} = Dynamo.put_item(t_name(),out_edge)
    out_edge
  end
  def add_in_edge(graph,aid,bid,label) when is_binary(aid) and is_binary(bid) do
    ie_id = cast_id(bid,:in_edge)
    ie_r = aid <> Atom.to_string(label)
    ie_map = %{
      id: ie_id,
      r: ie_r,
      label: label,
      e_type: :in
      # TODO: ensure we don't want the term in both edges, only :out_edge
      #map: term
    }
    in_edge = Map.merge(%Ddb.E{},ie_map)
    Logger.debug inspect in_edge
    {:ok,%{}} = Dynamo.put_item(t_name(),in_edge)
    in_edge
  end
  def add_out_nbr(aid,bid,label)  when is_binary(aid) and is_binary(bid) do
    #Logger.error inspect [aid,bid,label]
    out_map = %{
      id: cast_id(aid,:out_neighbor),
      label: label,
      nbr_type: :out,
      r: bid}
    out_nbr = struct(Ddb.N,out_map)
    {:ok,%{}} = Dynamo.put_item(t_name(),out_nbr)
  end
  def add_in_nbr(aid,bid,label) when (is_binary(aid) and is_binary(bid)) do
    in_map = %{
      id: cast_id(bid,:in_neighbor),
      label: label,
      nbr_type: :in,
      r: aid}
    in_nbr = struct(Ddb.N,in_map)
    {:ok,%{}} = Dynamo.put_item(t_name(),in_nbr)
  end
  def add_edge(graph,%{} = a, %{} = b,label, %{} = term) when is_atom(label)  do
    add_edge(graph,a.id,b.id,label,term)
  end
  def add_edge(graph,aid,bid,label, %{} = term) when is_atom(label) do
    #TODO: perfect case for using Tasks and concurrency
    children = []
    pid = self()
    
    #setup out_edge
    children = [spawn(fn-> add_out_edge(graph,aid,bid,label,term);send(pid,self); end) | children]

    # setup in_edge for b
    children = [spawn(fn-> add_in_edge(graph,aid,bid,label);send(pid,self); end) | children]
    # setup neightbors

    #out
    children = [spawn(fn-> add_out_nbr(aid,bid,label);send(pid,self); end) | children]
        #in
    children = [spawn(fn-> add_in_nbr(aid,bid,label);send(pid,self); end) |children]
    wait_on(children)
    #out_edge
  end
  def add_edge(graph,a,b,label,term) do
    raise "add_edge/5 must use a atom as a label, and map as a term #{inspect [a,b,label,term]}"
  end
  def decode_vertex({:ok, %{}}) do
    raise "empty"
  end
  def decode_vertex(raw) do
    map = Dynamo.Decoder.decode(raw) 
      |> keys_to_atoms
    Map.merge(%Ddb.V{},map)
  end
  #@nid_reg ~r/^(?<id>.+)_[i|o]nbr$/
  def id_from_neighbor(s) do
    #r = Regex.named_captures(@nid_reg,s)
    #r["id"]
    Logger.info inspect s
    cast_id(s,:node)
  end
  def out(graph) do
    stream = Stream.flat_map(graph.stream,fn(vertex) ->
      graph = out(graph,vertex) 
      Logger.debug "out(graph): \n\n\t#{inspect Enum.to_list(graph.stream)}"
      graph.stream
    end)
    Map.put(graph,:stream,stream)
  end
  def out(graph,vertex) do
    eav = [id: cast_id(vertex.id,:out_neighbor)]
    kce = "id = :id "
    r = Dynamo.stream_query(t_name(),
      expression_attribute_values: eav,
      key_condition_expression: kce)
    stream = Stream.flat_map(r,fn(raw) -> 
      item = Dynamo.Decoder.decode(raw,as: Ddb.N)
      r = id_from_neighbor(item.r)
      g = v_id(graph,r)
      g.stream
    end)
    Map.put(graph,:stream,stream)
  end
  @doc "get all neighbors with in edges from a stream of vertexes"
  def inn(graph) do
    stream = Stream.flat_map(graph.stream,fn(vertex) ->
      inn(graph,vertex).stream
    end)
    Map.put(graph,:stream,stream)
  end
  @doc "get all neighbors with in edges from a single vertex"
  def inn(graph,%Ddb.V{} = vertex) do
    eav = [id: "#{vertex.id}_inbr"]
    kce = "id = :id "
    r = Dynamo.stream_query(t_name(),
      expression_attribute_values: eav,
      key_condition_expression: kce)
    stream = Stream.flat_map(r,fn(raw) ->
      item = Dynamo.Decoder.decode(raw,as: Ddb.N)
      g = v_id(graph,item.r)
      g.stream
    end)
    Map.put(graph,:stream,stream)
  end
  @doc "get neighbors with matching attributes with in edges for mmap"
  def inn(graph,mmap) when is_map(mmap) do
    g = inn(graph)
    stream = Stream.filter(g.stream,fn(vertex) ->
      Logger.debug inspect vertex
      mmatch(vertex,mmap)
      #mmatch(mmap,vertex)
    end)
    Map.put(graph,:stream,stream)
  end
  def update_v(graph) do
    stream = Stream.flat_map(graph.stream, fn(vertex) ->
      update_v(graph,vertex).stream
    end)
    Map.put(graph,:stream,stream)
  end
  def update_v(graph,%Ddb.V{id: id} = vertex) do
    Logger.warn "update should update, but we have it putting a new item instead"
    create_v(graph,vertex)
    #Dynamo.update_item(t_name(),id, 
  end
  @doc "deletes a list of vertexes from a stream" 
  def del_v(graph) do
    Stream.each(graph.stream,fn(vertex) ->
      del_v(graph,vertex)
    end)
    #TODO: do we need to put in some metadata here?
    Map.put(graph,:stream,[])
  end
  @doc "deletes a vertex"
  def del_v(graph,%Ddb.V{id: id,r: r} = v) do
    epg = outE(graph, v)  
    #TODO: worth parallelizing?
    #TODO: deleting labeld in_edges seems expensive, can we omit labels for edges if neede?
    Enum.each(epg.stream,  fn(edge_pointer) ->
      Logger.debug "del_v: ep: #{inspect edge_pointer}"
      edge = e(edge_pointer)
      Logger.debug "del_v: starting children"
      # remove :in_edge
      children = []
      pid = self()
      children = [spawn( fn-> del_ie(edge);send(pid,self); end) | children]

      #remove :out_neighbor
      children = [spawn( fn-> del_on(edge);send(pid,self) end) | children]

      #remove :in_neighbor
      children = [spawn( fn-> del_in(edge);send(pid,self) end) | children]

      # delete out_edge fro source vertex
      children = [spawn( fn->  del_e(graph,edge_pointer);send(pid,self) end) | children]
      wait_on(children)
    end)
    # delete vertex
    Dynamo.delete_item(t_name(),[id: id,r: r])
  end
  @doc "wait for a message from children pids from spawn"
  def wait_on([]) do
    Logger.debug "children are done, nice!"
    nil
  end
  def wait_on(children) do
    receive do
      pid when is_pid(pid) -> 
        Logger.debug "child: #{inspect pid} done!"
        wait_on(List.delete(children,pid))
    end
  end
  @doc "delete in edge"
  def del_ie(edge) do
    ie_id = cast_id(edge.target_id,:in_edge)
    ie_r = cast_id(edge.id,:node) <> Atom.to_string(edge.label)
    ie_ptr = {ie_id,ie_r} 
    del_e(graph,ie_ptr)
  end
  def del_on(edge) do
    out_n_id = cast_id(edge.id,:out_neighbor)
    out_n_r = cast_id(edge.target_id,:node)
    del_e(graph,{out_n_id,out_n_r})
  end
  def del_in(edge) do
    in_n_id = cast_id(edge.target_id,:in_neighbor)
    in_n_r = cast_id(edge.id,:node)
    del_e(graph,{in_n_id,in_n_r})
  end
  @doc "delete labels maybe not needed" 
  def del_l(graph,%Ddb.V{id: id, r: r} = v) do
    raise "TODO: figure out if we need this"
    label_id = cast_id(id,:edge_label)
    #Enum.each(stream,fn(raw) ->
      #Dynamo.delete_item(t_name(),[id: item.id, r: item.r])
    #end)
  end
  def v(graph,map) when is_map(map) do
    case Map.has_key?(map,:r) do
      true -> v_id(graph,{map.id,map.r})
      false -> v_id(graph,map.id)
    end
  end
  @doc "this should be @hack tagged"
  def keys_to_atoms(map) do
    Enum.reduce(Map.keys(map),%{}, fn(key,acc) ->
      Map.put(acc,String.to_existing_atom(key),map[key])
    end)
  end
  def v_id(key) do
    v_id(graph(),key)
  end
  def v_id(graph,{nil,_}) do
    raise "v_id/2 can't go fetch a vertex with nil as the id!"
  end
  def v_id(graph,{id,r}) do
    Logger.debug "getting item\n\tid: #{inspect id}\n\tr: #{inspect r}"
    #map = Dynamo.get_item!(t_name(),%{id: id,r: r})
      #|> Dynamo.Decoder.decode() |> keys_to_atoms
    #Logger.debug("raw item: #{inspect map,pretty: true}")
    ## preserve additional attributes by not using as:
    #map = Map.merge(%Ddb.V{},map)
      #|> Dynamo.Decoder.decode(as: Ddb.V)
    case Dynamo.get_item(t_name(),%{id: id, r: r}) do
      {:ok,map} when map == %{} -> 
        Logger.warn "empty result for #{inspect [id,r]}"
        stream = []
      {:ok,raw} when is_map(raw) ->
      #raw -> 
        Logger.debug inspect raw
        stream = [decode_vertex(raw["Item"])]
      doh -> raise "the horror #{inspect doh}"
    end
    #map = Dynamo.get_item!(t_name(),%{id: id, r: r}) 
      #|> decode_vertex
    Map.put(graph,:stream,stream)
  end
  @doc "hack to keep range keys but not require them"
  def v_id(graph,id) when is_binary(id) do
    r = "0"
    v_id(graph,{id,r})
  end
  def v_id(graph,id) when is_number(id) do
    raise "id can't be a number right now, need to implement way to configure schema and table for that type and check it correctly"
  end
  def inE(graph,vertex) when is_map(vertex) do
    eav = [id: "in_edge",r: "#{vertex.id}_"]
    kce = "id = :id AND begins_with (r,:r)"
    r = Dynamo.stream_query(t_name(),
      expression_attribute_values: eav,
      key_condition_expression: kce)
  end
  @doc "get all out edges from stream of vertexes"
  def outE(graph) do
    stream = Stream.flat_map(graph.stream,fn(vertex) ->
      outE(graph,vertex).stream
    end)
    Map.put(graph,:stream,stream)
  end
  @doc "gets all out edges for a single vertex, uses %Trabant.V{} :id"
  def outE(graph,%Ddb.V{} = vertex) when is_map(vertex) do
    Logger.debug "getting edges for vertex: #{inspect vertex}"
    eav = [id: cast_id(vertex.id,:out_edge)]
    kce = "id = :id"
    stream = Dynamo.stream_query(t_name(),
      expression_attribute_values: eav,
      key_condition_expression: kce)
    #Logger.debug "raw Dynamo stream\n\n\n" <> inspect Enum.to_list stream
    #stream = Stream.map(stream, &Dynamo.Decoder.decode(&1,as: Ddb.E))
    stream = Stream.map(stream,fn(raw) ->
      r = Dynamo.Decoder.decode(raw) 
      s = Dynamo.Decoder.decode(raw,as: Ddb.E)
      Map.merge(s,r["map"])
    end)
    Logger.debug "as Ddb.E stream\n\n\n" <> inspect Enum.to_list(stream), pretty: true
    stream = Stream.map(stream, &({&1.id,&1.r}))
    #Logger.debug "to go into graph stream\n\n\n" <> inspect Enum.to_list(stream), pretty: true

    Map.put(graph,:stream,stream)
  end

  @doc "get label, labels should be used for indexing mostly"
  def outE(graph,label_key) when is_atom(label_key)do
    stream = Stream.flat_map(graph.stream,fn(vertex) ->
      # TODO: should consider index for this
      Stream.filter(outE(graph,vertex).stream, fn(edge_pointer) ->
        e = parse_pointer(edge_pointer)
        Logger.debug "outE(#{label_key}) ep: #{inspect e}"
        e[:label] == label_key
      end)
    end)
    Map.put(graph,:stream,stream)
  end
  @doc "match map for outE"
  def outE(graph,match_map) when is_map(match_map) do

    # get vertexes
    stream = Stream.flat_map(graph.stream,fn(vertex) ->
      Logger.debug "match map for outE vertex: #{inspect vertex}"
      # get edge pointers
      edges = outE(graph,vertex)
      checked_edges = check_edges(edges,match_map)
      # remove nil results
      #Logger.debug "checked edges #{inspect Enum.to_list(checked_edges)}"
      #Logger.debug "done checking edges"
      Stream.filter(checked_edges,&(&1 != nil))
      #Enum.filter(edges,&(&1 != nil))
    end)
    #Logger.debug "start"
    #Logger.debug "output stream from outE mmap: #{inspect Enum.to_list(stream)}"
    #Logger.debug "done"
    Map.put(graph,:stream,stream)
  end
  @doc "compares a list of edge pointers to a map to see if the attributes and values exist in the edge"
  defp check_edges(edges,match_map) do
    Stream.map(edges.stream,fn(edge_pointer) ->
      Logger.debug "edge pointer: #{inspect edge_pointer}"
        edge = e(edge_pointer)
        #test if edge matches
        case mmatch(edge,match_map) do
          true ->
            Logger.debug "match: #{}\n\t#{inspect edge_pointer}"
            # TODO: consider option to return %Trabant.E vs edge pointer
            #%Trabant.E{pointer: pointer, a: a, b: b, label: label}
            edge_pointer
         false ->
           #Logger.debug "no match #{inspect edge_pointer}\n\te:  #{inspect edge, pretty: true}"
           nil
       end
    end)
  end
  #@out_reg ~r/^(?<out_id>.*)_(?<label>.*)/
  #@id_reg ~r/^out_edge-(?<id>.*)$/
  def parse_pointer({nil,_}) do
    raise "nil no workie in parse_pointer/1"
  end
  def parse_pointer({aid,bid_and_label}) do
    #map = Regex.named_captures(@id_reg,a) |> Map.merge(Regex.named_captures(@out_reg,b))
    Logger.debug "parse_pointer \n\t#{inspect aid} \n\t#{inspect bid_and_label}"
    #Map.put(map,"label",Poison.decode!(map["label"],keys: :atoms))
    << bid :: binary-size(33),label :: binary >> = bid_and_label
    %{aid: cast_id(aid,:node),bid: cast_id(bid,:node), label: String.to_existing_atom(label)}
  end
  def parse_pointer(foo) do
    raise "bad pointer #{inspect foo}"
  end
  @doc "fetches unique vertexes from a list of edge pointers"
  def inV(graph) do
    stream = Stream.flat_map(graph.stream,fn(edge_pointer) ->
      Logger.debug "EP: #{inspect edge_pointer}"
      edge = parse_pointer(edge_pointer)
      Logger.debug "inV fetching node id: #{edge.bid}"
      v_id(graph,edge.bid) |> data
    end)
    #TODO: possible infinite loop here
    stream = Stream.uniq(stream)
    Map.put(graph,:stream,stream)
  end
  @doc "get verteces with matching attribute keys"
  def inV(graph,key) when is_atom(key) do
    #TODO: should be able to optimize with label indexes
    stream = Stream.filter(inV(graph).stream,fn(vertex) ->
      Map.has_key?(vertex,key)
    end)
    Map.put(graph,:stream,stream)
  end
  def inV(graph,mmap) when is_map(mmap) do
    stream = Stream.filter(inV(graph).stream,fn(vertex) -> 
      mmatch(vertex,mmap)
    end)
    Map.put(graph,:stream,stream)
  end
  def e(graph,{id,r}) do
    e({id,r})
  end
  def e({id,r}) do
    raw = Dynamo.get_item!(t_name(),%{id: id, r: r}) #|> Dynamo.Decoder.decode(as: Ddb.E)
    r = Dynamo.Decoder.decode(raw)
    s = Dynamo.Decoder.decode(raw,as: Ddb.E)
    map = Map.merge(s,r["map"])
    #<< target_id :: binary-size(33), label :: binary >> = map.r
    #target = cast_id(target_id,:)
    #map = Map.put(map,:target, target)
    Logger.debug "e() raw: #{inspect map}"
    map
  end
  def q(graph,map) do
    eav = Map.to_list(map)
    kce = map |> Enum.map(fn({k,v})-> "#{k} = :#{k}" end) |> Enum.join(",")
    Logger.debug "eav: #{inspect eav}\nkce: #{inspect kce}"
    r = Dynamo.stream_query(t_name(),
      expression_attribute_values: eav,
      key_condition_expression: kce)
    raise "TODO: not done yet"
  end
  def all_v(graph) do
    Logger.debug "all_v runs a full table scan!"
    eav = [r: "0"]
    r = Dynamo.stream_scan(t_name(),
      filter_expression: "r = :r",
      expression_attribute_values: eav)
    stream = Stream.map(r,fn(raw) ->
      decode_vertex(raw)
    end)
    Map.put(graph,:stream,stream)
  end
  def del_e(graph) do
    stream = Stream.flat_map(graph.stream,fn(edge_pointer) ->
      e = e(edge_pointer)
      #Dynamo.delete_item!(t_name(),%{id: e.id,r: e.r})
      Logger.info "del_e: e:\n\t#{inspect e}"
      del_e(graph,e)
    end)
    Map.put(graph,:stream,stream)
  end
  def del_e(graph,%Ddb.E{} = e) do
    Dynamo.delete_item(t_name(),%{id: e.id,r: e.r})
  end
  def del_e(graph,{id,r}) do
    Dynamo.delete_item(t_name(),%{id: id, r: r})
  end
  #def all(graph) do
  #  Dynamo.steam_scan(t_name()) |> Enum.map( &(Dynamo.Decoder.decode(&1)))
  #end
  #  Example of stream_query
  #
  # iex(23)> t |> Dynamo.stream_query(limit: 1, expression_attribute_values: [id: "1"],key_condition_expression: "id = :id")
  #  {:ok,
  #  %{"Count" => 1, "Items" => #Function<25.29647706/2 in Stream.resource/3>,
  #  "ScannedCount" => 1}}
  #  iex(24)> t
  #  "Users-dev"
  #
  defdelegate cast_id(s,a), to: Trabant
  defdelegate parse_id(s), to: Trabant
  defdelegate id_type?(x), to: Trabant
  defdelegate create_binary_id(s), to: Trabant
  defdelegate create_string_id(s), to: Trabant
  defdelegate data(graph), to: Trabant
  defdelegate first(graph), to: Trabant
  defdelegate limit(graph), to: Trabant
  defdelegate limit(graph,limit), to: Trabant
  defdelegate res(graph), to: Trabant
  defdelegate mmatch(target,test), to: Trabant
  defdelegate create_child(graph,opts), to: Trabant
end
