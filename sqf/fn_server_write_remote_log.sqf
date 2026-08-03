if (Debug_Logging) then {diag_log format["Executing: %1",__FILE__];};
private ["_player","_filename","_remoteLog"];
//[[B 1-1-B:1 (PLAYER1) REMOTE,"WriteLog",[array of message]],3]
_player = objectFromNetID ((_this select 0) select 0);
_filename = ((_this select 0) select 2) select 0;
_remoteLog = tostring(((_this select 0) select 2) select 1);

diag_log _remoteLog;
"dzfunctions" callExtension format["writeLog:%1:%2", _filename, _remoteLog];
