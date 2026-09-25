unit pascal_agent_service_unit;

{$DEFINE FPC_DELPHI_MODE}
{$I zNetV2\source\Z.Define.inc}

interface

uses
  SysUtils, Classes,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Json, Z.Status, Z.UnicodeMixedLib,
  lingofuse_import;

const
  APP_NAME = 'agent_main_app';
  APP_DESC = 'agent main application';
  IPC_ENDPOINT = 'ipc:agent';
  TCP_LISTEN_ADDR = '0.0.0.0:9897';
  TCP_PUBLIC_ADDR = '127.0.0.1:9897';

var
  App: TAppHnd;

procedure init_pascal_agent_service;
procedure free_pascal_agent_service;

implementation

type
  // Thread-safe storage for dynamically registered tool definitions.
  // Each entry is an independent root JSON object describing one tool.
  TRegisteredAgent = class(TBigList<TZ_JsonObject>)
  public
    procedure DoFree(var Data: TZ_JsonObject); override;
  end;

procedure TRegisteredAgent.DoFree(var Data: TZ_JsonObject);
begin
  DisposeObjectAndNil(Data);
  inherited DoFree(Data);
end;

var
  RegisteredAgent: TRegisteredAgent;

  // ============================================================================
  // API Callbacks
  // ============================================================================

// Callback for the agent_log API.
// Reads a JSON request from the input handle, extracts the "message" field
// (or falls back to the raw payload), logs it via DoStatus, and writes a
// JSON response of the form {"status":"ok"} to the output handle.
// On failure the response is {"status":"error","message":"..."}.
procedure do_agent_log(Trigger: Pointer; Input: TDataHnd; Output: TDataHnd); cdecl;
var
  jsonBytes: TBytes;
  jo: TZ_JsonObject;
  msg: string;
  ori_msg: TZ_JsonString;
begin
  jo := TZ_JsonObject.Create;
  try
    // Read the input payload (UTF-8 bytes, null-terminated by the writer).
    jsonBytes := LF_ReadStringBytes(Input);
    jo.Parae(jsonBytes);
    ori_msg.UTF8 := jsonBytes;

    // Extract the "message" field; fall back to the raw payload if absent.
    if jo.Exists('message') then
      msg := jo.S['message']
    else
      msg := ori_msg.Text;

    // Emit the log message (also visible in the console).
    if msg <> '' then
      DoStatus('[agent_log] %s', [msg]);

    // Respond with success.
    jo.Clear;
    jo.S['status'] := 'ok';
    LF_WriteStringBytes(Output, jo.ToBytes);
  except
    on E: Exception do
    begin
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Internal error: ' + E.Message;
      // Emit directly as bytes to avoid a temporary TZ_JsonString allocation.
      LF_WriteStringBytes(Output, jo.ToBytes);
      DoStatus('[agent_log] Exception: %s', [E.Message]);
    end;
  end;
  jo.Free;
end;

// Callback for the agent_main API.
//
// Returns a JSON object with a "tools" array. The array contains one entry
// for the built-in tool (agent_log) plus one entry for every dynamically
// registered tool whose target API is currently reachable.
//
// Each tool entry has the shape:
//   {
//     "name":        "<tool name>",
//     "description": "<human-readable description>",
//     "target_app":  "<application name>",
//     "target_api":  "<API name>",
//     "parameters":  <JSON Schema object>
//   }
//
// IMPORTANT: TZ_JsonObject is a tree. Assign / ParseText / Parae /
// LoadFromStream must only be called on root objects. To stay compliant,
// this routine assembles the whole response as a Unicode string, then
// parses it into a fresh independent root object before emitting bytes.
procedure do_agent_main(Trigger: Pointer; Input: TDataHnd; Output: TDataHnd); cdecl;
var
  jsonText: USystemString;
  tempJson: TZ_JsonString;
  toolCount: integer;
  rootObj: TZ_JsonObject;
begin
  jsonText := '{"tools":[';

  // Built-in tool entry: agent_log.
  jsonText := jsonText + '{"name":"agent_log",' + '"description":"Send log messages to the backend",' + '"target_app":"' + APP_NAME +
    '",' + '"target_api":"agent_log",' + '"parameters":{"type":"object",' + '"properties":{"message":{"type":"string",' +
    '"description":"Log message content"}},' + '"required":["message"]}}';

  toolCount := 1;

  // Append every dynamically registered tool that passes validation
  // and whose target API is currently reachable on the mesh.
  if RegisteredAgent <> nil then
  begin
    RegisteredAgent.Lock;
    try
      if RegisteredAgent.Num > 0 then
        with RegisteredAgent.Repeat_ do
          repeat
            // Only advertise entries that carry all mandatory fields.
            if queue^.Data.Exists('name') and queue^.Data.Exists('description') and queue^.Data.Exists('target_app') and
              queue^.Data.Exists('target_api') and queue^.Data.Exists('parameters') then
            begin
              // Only advertise tools whose target API is actually reachable.
              if LF_CheckApiEx(queue^.Data.S['target_app'], queue^.Data.S['target_api']) then
              begin
                // Serialise the stored tool definition to a compact JSON string
                // and append it verbatim. This never touches child objects.
                tempJson := queue^.Data.ToJSONString(False);
                jsonText := jsonText + ',' + tempJson.Text;
                Inc(toolCount);
                DoStatus('[agent_main] Included dynamic tool: %s (API %s.%s available)', [queue^.Data.S['name'], queue^.Data.S['target_app'],
                  queue^.Data.S['target_api']]);
              end
              else
                DoStatus('[agent_main] Skipped dynamic tool "%s": API %s.%s not available', [queue^.Data.S['name'], queue^.Data.S['target_app'],
                  queue^.Data.S['target_api']]);
            end
            else
            begin
              tempJson := queue^.Data.ToJSONString(False);
              DoStatus('[agent_main] Skipped invalid tool registration (missing fields) for: %s',
                [tempJson.Text]);
            end;
          until not Next;
    finally
      RegisteredAgent.UnLock;
    end;
  end;

  jsonText := jsonText + ']}';

  // Parse the assembled JSON into a fresh independent root object, then
  // emit its UTF-8 bytes. This is the only place ParseText is called, and
  // it operates on a root, so it complies with the tree rules.
  rootObj := TZ_JsonObject.Create;
  try
    rootObj.ParseText(jsonText);
    LF_WriteStringBytes(Output, rootObj.ToBytes);
  finally
    rootObj.Free;
  end;

  DoStatus('[agent_main] Tool list sent (%d tools)', [toolCount]);
end;

// Callback for the register_agent API.
//
// Accepts a JSON tool definition and validates the required fields:
// name, description, target_app, target_api, parameters.
//
// If a tool with the same name already exists, its definition is replaced.
// Otherwise a new entry is added to the pool.
//
// Returns {"status":"ok"} on success, or
// {"status":"error","message":"..."} on failure.
// Errors are logged and never re-raised.
procedure do_register_agent(Trigger: Pointer; Input: TDataHnd; Output: TDataHnd); cdecl;
var
  jsonBytes: TBytes;
  jo: TZ_JsonObject;
  toolObj: TZ_JsonObject;
  toolName: string;
  found: boolean;
begin
  jo := TZ_JsonObject.Create;
  try
    // Read and parse the input payload. jo is a root object, so Parae is safe.
    jsonBytes := LF_ReadStringBytes(Input);
    jo.Parae(jsonBytes);

    // Validate the required fields.
    if not jo.Exists('name') then
    begin
      DoStatus('[register_agent] Error: Missing "name" field');
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Missing "name" field';
      LF_WriteStringBytes(Output, jo.ToBytes);
      Exit;
    end;
    if not jo.Exists('description') then
    begin
      DoStatus('[register_agent] Error: Missing "description" field');
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Missing "description" field';
      LF_WriteStringBytes(Output, jo.ToBytes);
      Exit;
    end;
    if not jo.Exists('target_app') then
    begin
      DoStatus('[register_agent] Error: Missing "target_app" field');
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Missing "target_app" field';
      LF_WriteStringBytes(Output, jo.ToBytes);
      Exit;
    end;
    if not jo.Exists('target_api') then
    begin
      DoStatus('[register_agent] Error: Missing "target_api" field');
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Missing "target_api" field';
      LF_WriteStringBytes(Output, jo.ToBytes);
      Exit;
    end;
    if not jo.Exists('parameters') then
    begin
      DoStatus('[register_agent] Error: Missing "parameters" field');
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Missing "parameters" field';
      LF_WriteStringBytes(Output, jo.ToBytes);
      Exit;
    end;

    toolName := jo.S['name'];

    // Search for an existing tool with the same name.
    // Both queue^.Data and toolObj are independent root objects here,
    // so Assign on them is safe.
    found := False;
    if RegisteredAgent <> nil then
    begin
      RegisteredAgent.Lock;
      try
        if RegisteredAgent.Num > 0 then
          with RegisteredAgent.Repeat_ do
            repeat
              if umlMultipleMatch(toolName, queue^.Data.S['name']) then
              begin
                // Replace the existing definition.
                queue^.Data.Assign(jo);
                found := True;
                Break;
              end;
            until not Next;

        // Add a new entry if no match was found.
        if not found then
        begin
          toolObj := TZ_JsonObject.Create;
          toolObj.Assign(jo);
          RegisteredAgent.Add(toolObj);
        end;
      finally
        RegisteredAgent.UnLock;
      end;
    end;

    if not found then
      DoStatus('[register_agent] Added new tool: %s "%s"', [toolName, jo.S['description']])
    else
      DoStatus('[register_agent] Updated existing tool: %s "%s"', [toolName, jo.S['description']]);

    // Return success.
    jo.Clear;
    jo.S['status'] := 'ok';
    LF_WriteStringBytes(Output, jo.ToBytes);
  except
    on E: Exception do
    begin
      DoStatus('[register_agent] Exception: %s', [E.Message]);
      jo.Clear;
      jo.S['status'] := 'error';
      jo.S['message'] := 'Internal error: ' + E.Message;
      LF_WriteStringBytes(Output, jo.ToBytes);
    end;
  end;
  jo.Free;
end;

// ============================================================================
// Lifecycle
// ============================================================================

procedure init_pascal_agent_service;
begin
  // Create the storage for dynamically registered tools.
  RegisteredAgent := TRegisteredAgent.Create;

  // Create the LingoFuse application handle.
  App := LF_CreateAppEx(APP_NAME, APP_DESC);

  // Register the three APIs exposed by this service.
  LF_RegisterCallEx(App, 'agent_log', 'Logging tool', nil, @do_agent_log);
  LF_RegisterCallEx(App, 'agent_main', 'Tool list entry', nil, @do_agent_main);
  LF_RegisterCallEx(App, 'register_agent', 'Dynamic tool registration', nil, @do_register_agent);

  // Reset any previous preparation state, then prepare services and client.
  LF_PrepareServiceEx(IPC_ENDPOINT, IPC_ENDPOINT);
  LF_PrepareServiceEx(TCP_LISTEN_ADDR, TCP_PUBLIC_ADDR);

  // Connect locally to the IPC endpoint to expose the application.
  LF_PrepareClientEx(IPC_ENDPOINT, App);

  // Start the LingoFuse framework (blocks until ready or timeout).
  LF_PrepareDone;
end;

procedure free_pascal_agent_service;
begin
  // Stop the simulated main thread first.
  if LF_CheckMainThread() <> 0 then
  begin
    DoStatus('[MAIN] Shutting down...');
    LF_ExitMainThread;
  end;

  // Detach and release the application handle.
  if App <> nil then
  begin
    LF_FreeApp(App);
    App := nil;
  end;

  // Release the registered tool pool.
  if RegisteredAgent <> nil then
  begin
    DisposeObjectAndNil(RegisteredAgent);
    DoStatus('[MAIN] Cleanup complete.');
  end;
end;

end.
