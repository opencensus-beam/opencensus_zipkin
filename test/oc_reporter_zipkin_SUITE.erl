%%% ---------------------------------------------------------------------------
%%% @doc
%%% @end
%%% ---------------------------------------------------------------------------
-module(oc_reporter_zipkin_SUITE).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-include_lib("opencensus/include/opencensus.hrl").

all() ->
    [zipkin_reporter].

init_per_suite(Config) ->
    ok = application:load(opencensus),
    Config.

end_per_suite(_Config) ->
    ok = application:unload(opencensus),
    ok.

init_per_testcase(zipkin_reporter, Config) ->
    application:set_env(opencensus, reporter, {oc_reporter_zipkin, [{address, "http://ct-host:9411/endpoint"},
                                                                    {local_endpoint,
                                                                     #{<<"serviceName">> => "ct-service"}}]}),
    application:set_env(opencensus, sampler, {oc_sampler_always, []}),

    {ok, _} = application:ensure_all_started(opencensus),
    Config.

end_per_testcase(_, _Config) ->
    ok = application:stop(opencensus),
    ok.

zipkin_reporter(_Config) ->

    Self = self(),

    meck:new(httpc),
    meck:expect(httpc, request,
                fun (post, {"http://ct-host:9411/endpoint", [], "application/json", Content}, [], []) ->
                        Self ! {ok, Content},
                        {ok, {{ok, 202, ok}, ok, ok}};
                    (_, _, _, _)  ->
                        {ok, {{ok, 202, ok}, ok, ok}}
                end),

    try
        Parent = oc_trace:start_span(<<"Parent">>, undefined),
        Child = oc_trace:start_span(<<"span-name">>,
                                    Parent,
                                    #{attributes => #{<<"attr1">> => <<"val1">>,
                                                      <<"attr_as_function">> =>
                                                          fun () -> <<"val2">> end}}),

        Annotation = oc_span:annotation( <<"description">>, #{<<"key1">> => <<"value1">>,
                                                              <<"key2">> => <<"value2">>}),
        MessageEvent = oc_span:message_event('SENT', 5555, 200, 100),
        oc_trace:add_time_event(Annotation, Child),
        oc_trace:add_time_event(MessageEvent, Child),

        oc_trace:finish_span(Child),
        oc_trace:finish_span(Parent),

        ParentSpanId = iolist_to_binary(io_lib:format("~16.16.0b", [Parent#span_ctx.span_id])),
        ParentTraceId = iolist_to_binary(io_lib:format("~32.16.0b", [Parent#span_ctx.trace_id])),

        ChildSpanId = iolist_to_binary(io_lib:format("~16.16.0b", [Child#span_ctx.span_id])),

        receive
            {ok, Content} ->
                ?assertMatch([#{<<"annotations">> := [],
                                <<"debug">> := false,
                                <<"id">> := ParentSpanId,
                                <<"localEndpoint">> := #{<<"serviceName">> := "ct-service"},
                                <<"name">> := <<"Parent">>,
                                <<"shared">> := false,
                                <<"tags">> := #{},
                                <<"traceId">> := ParentTraceId},
                              #{<<"annotations">> :=
                                    [#{<<"timestamp">> := _,
                                       <<"value">> :=
                                           <<"description Attributes:{key1=value1, key2=value2}">>},
                                     #{<<"timestamp">> := _,
                                       <<"value">> :=
                                           <<"MessageEvent:{type=SENT, id=5555, uncompressed_size=200, "
                                             "compressed_size=100}">>}],
                                <<"debug">> := false,
                                <<"id">> := ChildSpanId,
                                <<"localEndpoint">> := #{<<"serviceName">> := "ct-service"},
                                <<"name">> := <<"span-name">>,
                                <<"parentId">> := ParentSpanId,
                                <<"shared">> := false,
                                <<"tags">> :=
                                    #{<<"attr1">> := <<"val1">>,
                                      <<"attr_as_function">> := <<"val2">>},
                                <<"timestamp">> := _,
                                <<"traceId">> := ParentTraceId}],
                             lists:sort(jsx:decode(Content, [return_maps])))

        after
            6000 -> ct:fail("Zipking reporter doesn't work")
        end
    after
        meck:validate(httpc),
        meck:unload(httpc)
    end.
