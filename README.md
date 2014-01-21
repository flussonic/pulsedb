Pulsedb
=======


This library is a storage for statistics like network usage, load, etc..

It is an append-only storage, that supports indexing and simple lookups of stored data.


Writing data
----------------------


    {ok, _} = pulsedb:open(my_database, "stats"), % Will call start_link
    pulsedb:append([
        {input, 1378950600, 432423, [{host,<<"host1.local">>,{iface,<<"eth0">>}}]},
        {output, 1378950600, 4324141232, [{host,<<"host1.local">>,{iface,<<"eth0">>}}]},

        {input, 1378950601, 435003, [{host,<<"host1.local">>,{iface,<<"eth0">>}}]},
        {output, 1378950601, 4324432132, [{host,<<"host1.local">>,{iface,<<"eth0">>}}]},

        {input, 1378950602, 442143, [{host,<<"host1.local">>,{iface,<<"eth0">>}}]},
        {output, 1378950602, 4328908132, [{host,<<"host1.local">>,{iface,<<"eth0">>}}]}
    ], my_database).


Pulsedb will create files 

    stats/2013/09/12/config_v3
    stats/2013/09/12/data_v3

You can delete old files without any problems. It is designed so that data for each day is written independently
in different folders.


You can write timestamps in any order. If you want to upload delayed timestamps, no problems: pulsedb will write it.




Reading data
------------


    {ok, Ticks, _} = pulsedb:read("sum:output{from=2013-09-12,to=2013-09-13}", my_database),
    {ok, Ticks2, _} = pulsedb:read("sum:1m-avg:output{from=1378950600,to=1378950800,host=host1.local}", my_database).

Syntax of query is like in OpenTSDB



Subscribing
-----------










