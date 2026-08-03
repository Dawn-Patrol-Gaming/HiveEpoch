# HiveEpoch
Replacement for Arma 2 OA DayZ Epoch HiveExt.dll

Direct port of https://github.com/icomrade/icomradeHiveEpoch and https://github.com/vbawol/DayZhiveEpoch

This version of HiveExt does not require C++ runtimes, database connectivity dependencies or memory management dependencies like tbb.dll or tbbmalloc.dll like the original(s).

This is a direct replacement that can replace the original HiveExt.dll. The main code is in the folder "query_extension"

This also provides the same structure and format as extdb2.dll for Arma 3, enabling you to access custom SQL from an additional ini file named dbfunctions.ini

In the releases is a copy of HiveExt.dll and a testing app. Since most people won't be able to compile from source unless they own a copy of Embarcadero's Delphi (or RAD Studio) and the associated 3rd party components: Devart's UniDAC, I've attached precompiled binaries to this repo.

Examples on how to use custom queries:
https://github.com/Dawn-Patrol-Gaming/HiveEpoch/blob/main/sqf/readme.md

Nothing has changed in terms of functionality between the C++ version and this release. The main differences are:
1. You don't need the Visual C++ runtime packages installed any longer that were required in the C++ version.
2. You don't need DatabaseMySql.dll or DatabasePostgre.dll, this is all native to the DLL. PostgreSQL support has not been added but can be easily if there is demand for it.
3. You don't need memory managers tbb.dll or tbbmalloc.dll any longer.
4. This natively connects and works with all MySQL and MariaDB versions (including MySQL 9), it highly unlikely to have any connectivity issues when new versions come out, if it does, it's a simple recompile.
5. This supports all authentication methods for MySQL and MariaDB (hive had trouble in the past when they changed auth methods, namely TLS 1.2 for MySQL)

I know there were a few issues with exceptions and leaks on teardown of the original dll that have been fixed in this version - most people wouldn't have noticed those anyways.

I am not going to change any part of the original hive functionality. There will be no additions of new "CHILD" calls into the dll, or any changes to the existing calls. The addition of customizing your queries removes the need to ever alter the original hive code again.

There are example SQF and ini files for using the custom query engine in this DLL. It has been running on my personal DayZ Epoch servers for many years at this point and works quite well. I structured the custom query engine to mimic extDB2 for Arma 3 Exile.

While the custom query engine does not queue queries, I have yet to find an instance where it blocks execution of the main Arma thread for any significant amount of time regardless of how large your tables are. For instance, queries against object_data with 12-15k rows has had no significant performance degradation against the Arma 2 process. Even inserting into tables with 100k + rows, I have not seen any performance issues. If you have performance issues, the first thing you want to do is examine your index usage and try to tweak that first.

There are a couple things that are custom and not straight SQL in the custom engine but those are explained in the examples.

Before posting about any issues try to see if you can figure out what went wrong by changing the logging level inside hiveext.ini, switching it to informational or debug will often clue you in on what's wrong. Most error messages will tell you pretty much what you need to know to fix whatever is broken.
