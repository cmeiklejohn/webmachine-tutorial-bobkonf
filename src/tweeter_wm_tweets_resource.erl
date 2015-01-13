-module(tweeter_wm_tweets_resource).

-export([init/1,
         routes/0,
         to_json/2,
         to_stream/2,
         from_json/2,
         create_path/2,
         generate_etag/2,
         post_is_create/2,
         allowed_methods/2,
         content_types_accepted/2,
         content_types_provided/2]).

-include_lib("webmachine/include/webmachine.hrl").

-record(context, {tweet, tweets}).

%% @doc Initialize the resource.
init([]) ->
    {ok, #context{}}.

%% @doc Support retrieval and creation of tweets.
allowed_methods(ReqData, Context) ->
    {['HEAD', 'GET', 'POST'], ReqData, Context}.

%% @doc Allow POST request to create tweet.
post_is_create(ReqData, Context) ->
    {true, ReqData, Context}.

%% @doc Return the routes this module should respond to.
routes() ->
    [{["tweets"], ?MODULE, []}].

%% @doc Generate etag for tweets.
generate_etag(ReqData, Context) ->
    {_, NewContext} =  maybe_retrieve_tweets(Context),
    ETag = mochihex:to_hex(erlang:phash2(NewContext#context.tweets)),
    {ETag, ReqData, NewContext}.

%% @doc Attempt to retrieve tweet list.
maybe_retrieve_tweets(Context) ->
    case Context#context.tweets of
        undefined ->
            Tweets = [encode({Key, Value})
                      || [{Key, Value}] <- ets:match(tweets, '$1')],
            {true, Context#context{tweets=Tweets}};
        _ ->
            {true, Context}
    end.

%% @doc Provide only application/json content.
content_types_provided(ReqData, Context) ->
    {[{"application/json", to_json},
      {"multipart/mixed", to_stream}], ReqData, Context}.

%% @doc Accept only application/json content.
content_types_accepted(ReqData, Context) ->
    {[{"application/json", from_json}], ReqData, Context}.

%% @doc Attempt to create the tweet if possible.
create_path(ReqData, Context) ->
    case maybe_create_tweet(ReqData, Context) of
        {true, NewContext} ->
            {Id, _} = NewContext#context.tweet,
            Resource = "/tweets/" ++ binary_to_list(time_to_timestamp(Id)),
            NewReqData = wrq:set_resp_header("Location", Resource, ReqData),
            {Resource, NewReqData, NewContext};
        {false, Context} ->
            {"/users", ReqData, Context}
    end.

%% @doc Build a tweet.
generate(Attributes) ->
    {struct, [{<<"tweet">>, {struct, Decoded}}]} =
                                        mochijson2:decode(Attributes),
    Id = erlang:now(),
    Message = proplists:get_value(<<"message">>, Decoded),
    Avatar = proplists:get_value(<<"avatar">>, Decoded),
    {Id, [{message, Message}, {avatar, Avatar}]}.

%% @doc Attempt to create and stash in the context if possible.
maybe_create_tweet(ReqData, Context) ->
    case Context#context.tweet of
        undefined ->
            Attributes = wrq:req_body(ReqData),
            Tweet = generate(Attributes),
            try
                _ = ets:insert(tweets, [Tweet]),

                %% Broadcast to all listeners.
                [Pid ! {tweet, Tweet} || Pid <- pg2:get_members(tweets)],

                {true, Context#context{tweet=Tweet}}
            catch
                _:_ ->
                    {false, Context}
            end;
        _Tweet ->
            {true, Context}
    end.

%% @doc Accept user input, attempt to create.
from_json(ReqData, Context) ->
    case maybe_create_tweet(ReqData, Context) of
        {true, NewContext} ->
            {_, Tweet} = NewContext#context.tweet,
            Response = mochijson2:encode({struct, [{tweet, Tweet}]}),
            NewReqData = wrq:set_resp_body(Response, ReqData),
            {true, NewReqData, NewContext};
        {false, Context} ->
            {{halt, 409}, ReqData, Context}
    end.

%% @doc Return the list of tweets.
to_json(ReqData, Context) ->
    {_, NewContext} = maybe_retrieve_tweets(Context),
    Content = mochijson2:encode({struct, 
                                 [
                                  {tweets, NewContext#context.tweets}
                                 ]}),
    {Content, ReqData, Context}.

%% @doc Return stream of tweets.
to_stream(ReqData, Context) ->
    case pg2:join(tweets, self()) of
        ok ->
            Boundary = unique_id_62(),
            NewReqData = wrq:set_resp_header("Content-Type",
                                             "multipart/mixed;
                                             boundary=" ++ Boundary,
                                             ReqData),
            {{stream, {<<>>, fun() -> stream(Boundary) end}},
             NewReqData, Context};
        _ ->
            {{halt, 500}, ReqData, Context}
    end.

%% @doc Stream data from the pipeline out.
stream(Boundary) ->
    Content = receive
        {tweet, Tweet} ->
            Tweet
    end,
    Body = ["\r\n--", Boundary,
            "\r\nContent-Type: application/json",
            "\r\n\r\n", encode(Content), "\r\n"],
    {Body, fun() -> stream(Boundary) end}.

%% @doc Convert time to unix time.
time_to_timestamp({Mega, Sec, Micro}) ->
    Time = Mega * 1000000 * 1000000 + Sec * 1000000 + Micro,
    list_to_binary(integer_to_list(Time)).

%% @doc Create a random identifying integer, returning its string
%%      representation in base 62.  Taken from basho/riak_core.
unique_id_62() ->
    Rand = crypto:hash(sha, term_to_binary({make_ref(), os:timestamp()})),
    <<I:160/integer>> = Rand,
    integer_to_list(I, 62).

%% @doc Encode a tweet.
encode({Key, Value}) ->
    Value ++ [{id, time_to_timestamp(Key)}].
