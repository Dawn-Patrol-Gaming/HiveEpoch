//note this is not suited for vanilla epoch, there are some custom functions called in here, but this is a good example of how to use
//the custom loading objects from the db script at server startup, customize to your needs - the main part is the building of _objArray
//from the dll, that is done with the "Create Objects" value in the ini file, you add your extra fields to that then code around it below

private ["_action","_idKey","_type","_ownerID","_worldspace","_inventory","_hitPoints","_fuel","_damage","_storageMoney","_objectName","_ownerUID","_list","_posATL",
"_maintenanceMode","_maintenanceModeVars","_dir","_pos","_wsDone","_wsCount","_vector","_vecExists","_ownerPUID","_worldSpaceSize","_ws2TN","_ws3TN","_object","_isVehicle"];
DZ_Allowed_Damage_List = [];
DZ_Reset_Inventory = [];
{
	_action = 		_x select 0; 
	_idKey = 		_x select 1;
	_type =			_x select 2;
	_ownerID = 		_x select 3;
	_worldspace = 	_x select 4;
	_inventory =	_x select 5;
	_hitPoints =	_x select 6;
	_fuel =			_x select 7;
	_damage = 		_x select 8;
	_storageMoney = _x select 9;

	_objectName = 	_x select 10;
	_ownerUID = 	_x select 11;

	//set object to be in maintenance mode
	_maintenanceMode = false;
	_maintenanceModeVars = [];
	
	_dir = 90;
	_pos = [0,0,0];
	_wsDone = false;
	_wsCount = count _worldspace;

	//Vector building
	_vector = [[0,0,0],[0,0,0]];
	_vecExists = false;
	_ownerPUID = "0";

	call {
		if (_wsCount == 4) exitwith {
			_dir = _worldspace select 0;
			_posATL = _worldspace select 1;
			if (count _posATL == 3) then {
				_pos = _posATL;
				_wsDone = true;
			};
			_ws2TN = typename (_worldspace select 2);
			_ws3TN = typename (_worldspace select 3);
			if (_ws3TN == "STRING") then {
				_ownerPUID = _worldspace select 3;
			} else {
				if (_ws2TN == "STRING") then {
					_ownerPUID = _worldspace select 2;
				};
			};
			if (_ws2TN == "ARRAY") then {
				_vector = _worldspace select 2;
				_vecExists = true;
			} else {
				if (_ws3TN == "ARRAY") then {
					_vector = _worldspace select 3;
					_vecExists = true;
				};
			};
		};
		if (_wsCount == 3) exitwith {
			_dir = _worldspace select 0;
			_posATL = _worldspace select 1;
			if (count _posATL == 3) then {
				_pos = _posATL;
				_wsDone = true;
			};
			_ws2TN = typename (_worldspace select 2);
			_ws3TN = typename (_worldspace select 3);
			if (_ws2TN == "STRING") then {
				_ownerPUID = _worldspace select 2;
			} else {
				 if (_ws2TN == "ARRAY") then {
					_vector = _worldspace select 2;
					_vecExists = true;
				};
			};
		};
		if (_wsCount == 2) then {
			_dir = _worldspace select 0;
			_posATL = _worldspace select 1;
			if (count _posATL == 3) then {
				_pos = _posATL;
				_wsDone = true;
			};
		};
		if (_wsCount < 2) exitwith {
			_worldspace set [count _worldspace, "0"];
		};
	};

	if (!_wsDone) then {
		if ((count _posATL) >= 2) then {
			_pos = [_posATL select 0,_posATL select 1,0];
			diag_log format["MOVED OBJ: %1 of class %2 with worldspace array = %3 to pos: %4",_idKey,_type,_worldspace,_pos];
		} else {
			diag_log format["MOVED OBJ: %1 of class %2 with worldspace array = %3 to pos: [0,0,0]",_idKey,_type,_worldspace];
		};
	};
	_isVehicle = _type call isVehicleClass;
	if (_isVehicle) then {
		_object = [_type, _pos, _dir,  !(surfaceIsWater _pos),false] call fn_careful_create_vehicle;
	} else {
		_object = _type createVehicle [0,0,0];
		//since this is a bulk load, don't send allowdamage to the client with the second param set to false
		_object setdamage _damage;
	};
	_object setVariable["_pos",_pos];//needed for other scripts since other position vars are slightly different
	_object setVariable ["OEMPos",_pos,true]; // used for inplace upgrades and lock/unlock of safe
	_object setVariable["memDir",_dir,true];
	if(_vecExists)then{
		_object setVectorDirAndUp _vector;
	} else {
		_object setDir _dir;
	};
	if !(_isVehicle) then {
		_object setPosATL _pos;
	};
	/* //this was for vehicles only, this is actually done in careful_create_vehicle
			if (surfaceisWater _pos) then {
			_object setPosASL _pos;
		} else {
			_object setPosATL _pos;
		};
	//*/
	//if (_idKey == "383350") then {diag_log format["getposatl %1",getposatl _object];diag_log format["getposasl %1",getposasl _object];};
	//_object enableSimulation false;
	_object setVariable ["OwnerPUID", _ownerPUID,true];

	_object setVariable["_action",_action];
	_object setVariable["_idKey",_idKey];
	_object setVariable["_type",_type];
	_object setVariable["_ownerID",_ownerID];
	_object setVariable["_worldspace",_worldspace];
	_object setVariable["_vector",_vector];
	_object setVariable["_vecExists",_vecExists];
	_object setVariable["_inventory",_inventory];
	_object setVariable["_hitPoints",_hitPoints];
	_object setVariable["_fuel",_fuel];
	_object setVariable["_damage",_damage];
	_object setVariable["_storageMoney",_storageMoney];

	_object setVariable["_objectName",_objectName];
	_object setVariable["_ownerUID",_ownerUID];

	_object setVariable ["ObjectID", _idKey, true];
	_object setVariable ["CharacterID", _ownerID, true];
	_object setVariable ["lastUpdate",diag_ticktime];
	_object setVariable ["objDone",false];
//need to load plot info early due to people logging in way too soon
	if (_object call isPlotPole) then {
		_object setVariable ["plotfriends", _inventory, true];//this needs to come after accesslist eval because it gets set depending on access list existing
		_object setVariable ["ObjectName", _objectName, true];
		_object setVariable ["OwnerUID", _ownerUID, true];
	};

//if ((_object isKindOf "LandVehicle") || (_object isKindOf "Ship") || (_object isKindOf "Air")) then {_object setVehicleLock "LOCKED";}; 
if (_isVehicle) then {_object setVehicleLock "LOCKED";};
dayz_serverIDMonitor set [count dayz_serverIDMonitor,_idKey];
dayz_serverObjectMonitor set [count dayz_serverObjectMonitor,_object];
[ DZ_Allowed_Damage_List, netID _object,"template.sqf"] call pushbackUnique;
true;
	//DZ_Object_Array set [count DZ_Object_Array, _object];
} count _objArray > 0;

dayz_serverObjectMonitor spawn {
	local _list = _this;
	{
		local _object = _x;
		local _isVehicle = (_object call isVehicleClass);
		if !(_isVehicle || (_object call isStorageClass) || (_object call isAccessListClass)) then {
			_object setVariable ["objDone",true,true];
		};
	} foreach _list;
};
