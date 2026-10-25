--  This program is intended to be run as a service publishing the results
--  from remote procedure calls to a SMA WebBox.

--  Author    : David Haley
--  Created   : 19/04/2026
--  Last Edit : 25/10/2026

--  20261025 : Include data from one inverter; Inv_Field_List keys obtained by
--  GetProcessDataChannels at startup. Send and receive code factored out for
--  reuse by all remote procedure calls. Receive buffer enlarged.
--  Inv_Field_List values and units updated by GetProcessData after each
--  GetPlantOverview, Poll_Interval maintained between all calls. All
--  Inv_Field_List fields published as "Name":"ValueUnit".
--  20261014 : Stale replies (id lower than expected) discarded and receive
--  retried, so one late reply no longer leaves every subsequent reply out of
--  step by one sequence number.
--  20260909 : Bug fix proposed by Claude to address power and yeild being
--  reported erroneously as 0 without any error being reported.
--  20260612 : Seperate configuration program orovided.
--  20260524 : Exception handling made more robust.

with Ada.Calendar; use Ada.Calendar;
with Ada.Calendar.Formatting; use Ada.Calendar.Formatting;
with Ada.Command_Line; use Ada.Command_Line;
with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Characters.Conversions; use Ada.Characters.Conversions;
with Ada.Streams; use Ada.Streams;
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Exceptions; use Ada.Exceptions;
with Ada.Containers.Ordered_Maps;
with GNAT.Sockets; use GNAT.Sockets;
with GNATCOLL.JSON; use GNATCOLL.JSON;
with DJH.JSON_Configuration;
with Linux_Signals; use Linux_Signals;
with MQTT_Client; use MQTT_Client;
with Common_Configuration; use Common_Configuration;

procedure Webbox_To_Mqtt is

   Webbox_RPC_Port : constant Port_Type := 34268;
   Reply_Timeout : constant Duration := 5.0;
   --  Should be an absolute eternity, typical time to reply was 300 ms in
   --  WireShark testing.
   Poll_Interval : constant Duration := 30.0; -- Minimum recommended 30 s
   subtype Sequence_Numbers is Positive;
   type Reply_Status is (Valid, Stale, Mismatch, Bad);

   --  Webbox JSON identifiers
   Proc : constant String := "proc";
   GetPlantOverview : constant String := "GetPlantOverview";
   GetProcessDataChannels : constant String := "GetProcessDataChannels";
   GetProcessData : constant String := "GetProcessData";
   Id : constant String := "id";

   package Configuration is new
      DJH.JSON_Configuration (Parameters, Configuration_File, Encrypted);
   use Configuration;

   type Inv_Fields is record
      Value : Unbounded_String := Null_Unbounded_String;
      Unit : Unbounded_String := Null_Unbounded_String;
   end record; -- Inv_Fields

   package Inv_Field_Lists is new
     Ada.Containers.Ordered_Maps (Unbounded_String, Inv_Fields);
   use Inv_Field_Lists;

   function Field (Object : in JSON_Value; Field_Name : in String)
                   return JSON_Value is
   begin -- Field
      --  Guards against calling a typed Get on a value of the wrong
      --  Kind, which raises Constraint_Error (Has_Field / typed Get
      --  access the matching variant record field without a Kind
      --  check); returns JSON_Null for a missing field or non-object.
      if Kind (Object) = JSON_Object_Type and then
        Has_Field (Object, Field_Name) then
         return Get (Object, Field_Name);
      else
         return JSON_Null;
      end if; -- Kind (Object) = JSON_Object_Type and then ...
   end Field;

   procedure Publish (Reply_Time : in Time;
                      Plant_String : in Unbounded_String;
                      Inv_Field_List : in Inv_Field_Lists.Map;
                      Publish_Handle : in MQTT_Handle) is

      Parsed : Read_Result;
      Id_Value, Proc_Value, Result, Overview, Entry_Object,
        Name_Value, Value_Value : JSON_Value;
      Data_Array : JSON_Array;
      Power_Found, Yield_Found : Boolean := False;
      Clock_JSON : constant JSON_Value := Create_Object;

      procedure Log_Rejected (Reason : in String) is

      begin -- Log_Rejected
         Put_Line ("Rejected - " & Reason);
         Put_Line (To_String (Plant_String));
      end Log_Rejected;

   begin -- Publish
      Parsed := Read (Plant_String);
      if not Parsed.Success then
         Log_Rejected (Format_Parsing_Error (Parsed.Error));
         return;
      end if; -- not Parsed.Success
      Id_Value := Field (Parsed.Value, Id);
      if Kind (Id_Value) /= JSON_String_Type then
         Log_Rejected ("id field missing or not a string");
         return;
      end if; -- Kind (Id_Value) /= JSON_String_Type
      Proc_Value := Field (Parsed.Value, Proc);
      if Kind (Proc_Value) /= JSON_String_Type or else
        To_String (Get (Proc_Value)) /= GetPlantOverview then
         Log_Rejected ("unexpected or missing proc");
         return;
      end if; -- Kind (Proc_Value) /= JSON_String_Type or else ...
      Result := Field (Parsed.Value, "result");
      Overview := Field (Result, "overview");
      if Kind (Overview) /= JSON_Array_Type then
         Log_Rejected ("result/overview missing or not an array");
         return;
      end if; -- Kind (Overview) /= JSON_Array_Type
      Data_Array := Get (Overview);
      for I in Natural range 1 .. Length (Data_Array) loop
         Entry_Object := Get (Data_Array, I);
         Name_Value := Field (Entry_Object, "name");
         Value_Value := Field (Entry_Object, "value");
         if Kind (Name_Value) = JSON_String_Type and then
           Kind (Value_Value) = JSON_String_Type then
            if To_String (Get (Name_Value)) = "GriPwr" then
               Power_Found := True;
               Set_Field (Clock_JSON, "power", To_String (Get (Value_Value)));
            elsif To_String (Get (Name_Value)) = "GriEgyTdy" then
               Yield_Found := True;
               Set_Field (Clock_JSON, "daily_yeild",
                          To_String (Get (Value_Value)));
            end if; -- To_String (Get (Name_Value)) = "GriPwr"
         end if; -- Kind (Name_Value) = JSON_String_Type and then ...
      end loop; -- I in Natural range 1 .. Length (Data_Array)
      if not (Power_Found and Yield_Found) then
         Log_Rejected ("GriPwr or GriEgyTdy not found in overview");
         return;
      end if; -- not (Power_Found and Yield_Found)
      for C in Inv_Field_List.Iterate loop
         --  Fields without a value (GetProcessData not yet successful) are
         --  omitted.
         if Inv_Field_List (C).Value /= Null_Unbounded_String then
            Set_Field (Clock_JSON, To_String (Key (C)),
                       To_String (Inv_Field_List (C).Value &
                         Inv_Field_List (C).Unit));
         end if; -- Inv_Field_List (C).Value /= Null_Unbounded_String
      end loop; -- C in Inv_Field_List.Iterate
      Set_Field (Clock_JSON, "message_time_utc", Image (Reply_Time));
      Send (Publish_Handle, Write (Clock_JSON));
   end Publish;

   --  Global variables used by Receiver and main program
      Client_Socket : Socket_Type;
      Webbox_Address : Sock_Addr_Type;
      Publish_Handle : MQTT_Handle;

   task Receiver is
      pragma Storage_Size (512 * 1024);
      --  Rx_Buffer and its String conversion are on this task's stack.
      entry Request_Sent (Sequence_Number : in Sequence_Numbers;
                          Reply : out Unbounded_String;
                          Reply_Time : out Time);
      entry Stop;
   end Receiver;

   task body Receiver is

      Rx_Buffer_Length : constant Stream_Element_Offset := 65536;
      --  Largest possible UDP payload, GetProcessData replies are large.
      Rx_Buffer : Stream_Element_Array (1 .. Rx_Buffer_Length);
      Rx_Wide_Reply : Wide_String (1 .. Positive (Rx_Buffer_Length / 2));
      for Rx_Wide_Reply'Address use Rx_Buffer'Address;
      pragma Import (Ada, Rx_Wide_Reply);
      Last : Stream_Element_Offset;
      Run : Boolean := True;

   begin -- Receiver
      while Run loop
         select
            accept Request_Sent (Sequence_Number : in Positive;
                                 Reply : out Unbounded_String;
                                 Reply_Time : out Time) do
               begin -- Receive exception block
                  Reply := Null_Unbounded_String;
                  Reply_Time := Clock + Reply_Timeout;
                  Receive_Socket (Client_Socket, Rx_Buffer, Last);
                  Reply_Time := Clock;
                  Reply :=
                    To_Unbounded_String (
                    To_String (Rx_Wide_Reply (1 .. Positive (Last / 2))));
               exception
                  when E : Socket_Error =>
                     if Resolve_Exception (E) /=
                         Resource_Temporarily_Unavailable
                     then
                        Put_Line ("Sequence" & Sequence_Number'Img &
                                  " receive error - " &
                                  Exception_Message (E));
                     end if; -- Resolve_Exception (E) /= ...
                     --  Resource_Temporarily_Unavailable is the expected
                     --  Receive_Socket timeout (SO_RCVTIMEO), silently
                     --  ignored, any other socket error is logged.
                  when E : others =>
                     Put_Line ("Sequence" & Sequence_Number'Img &
                               " unexpected error - " &
                               Exception_Information (E));
                     --  All other errors reported.
               end; -- Receive exception block
            end Request_Sent;
         or
            accept Stop do
               Run := False;
            end Stop;
         end select;
      end loop; -- Run
   end Receiver;

   function Check_Sequence (Sequence_Number : in Sequence_Numbers;
                            Reply : in Unbounded_String) return Reply_Status is

      Parsed : constant Read_Result := Read (Reply);
      Id_Value : JSON_Value;
      Reply_Id : Sequence_Numbers;

   begin -- Check_Sequence
      if not Parsed.Success then
         return Bad;
      end if; -- not Parsed.Success
      Id_Value :=Get (Parsed.Value, Id);
      if Kind (Id_Value) /= JSON_String_Type then
         return Bad;
      end if; -- Kind (Id_Value) /= JSON_String_Type
      begin -- Sequence_Number parse block
         Reply_Id := Sequence_Numbers'Value (To_String (Get (Id_Value)));
      exception
         when Constraint_Error =>
            return Bad;
      end; -- Sequence_Number parse block
      if Reply_Id < Sequence_Number then
         return Stale;
      elsif Reply_Id /= Sequence_Number then
         return Mismatch;
      else
         return Valid;
      end if; -- Reply_Id < Sequence_Number
   end Check_Sequence;

   procedure Send_Request (Sequence_Number : in Sequence_Numbers;
                           Request : in Wide_String) is

      Tx_Request : Wide_String := Request;
      Tx_Buffer_Length : constant Stream_Element_Offset :=
        Tx_Request'Size / Stream_Element'Size;
      Tx_Buffer : Stream_Element_Array (1 .. Tx_Buffer_Length);
      for Tx_Buffer'Address use Tx_Request'Address;
      pragma Import (Ada, Tx_Buffer);

      Last : Stream_Element_Offset;

   begin -- Send_Request
      Send_Socket (Client_Socket, Tx_Buffer, Last, Webbox_Address);
   exception
      when E : others =>
         Put_Line ("TX sequence:" & Sequence_Number'Img & " - " &
                   Exception_Message (E));
   end Send_Request;

   procedure Receive_Reply (Label : in String;
                            Sequence_Number : in Sequence_Numbers;
                            Reply : out Unbounded_String;
                            Reply_Time : out Time;
                            Status : out Reply_Status) is

   begin -- Receive_Reply
      loop -- receive
         Receiver.Request_Sent (Sequence_Number, Reply, Reply_Time);
         Status := Check_Sequence (Sequence_Number, Reply);
         case Status is
            when Valid =>
               exit;
            when Stale =>
               Put_Line (Label & " RPC stale reply received");
               null; -- try another receive
            when Bad =>
               Put_Line (Label & " RPC bad reply or timed out");
               exit; -- failed procedure call
            when Mismatch =>
               Put_Line (Label & " RPC mismatched Sequence_Number");
               exit;
         end case; -- Status
      end loop; -- receive
   end Receive_Reply;

   function Overview_Request (Sequence_Number : in Sequence_Numbers)
                              return Wide_String is

      RPC : constant Wide_String := "RPC=";
      JSON_Object : constant JSON_Value := Create_Object;

   begin -- Overview_Request
      Set_Field (JSON_Object, "version", "1.0");
      Set_Field (JSON_Object, Proc, GetPlantOverview);
      Set_Field (JSON_Object, Id, Trim (Sequence_Number'Img, Both));
      Set_Field (JSON_Object, "format", "JSON");
      return RPC & To_Wide_String (Write (JSON_Object));
   end Overview_Request;

   function Channels_Request (Sequence_Number : in Sequence_Numbers)
                              return Wide_String is

      RPC : constant Wide_String := "RPC=";
      JSON_Object : constant JSON_Value := Create_Object;
      Params : constant JSON_Value := Create_Object;

   begin -- Channels_Request
      Set_Field (JSON_Object, "version", "1.0");
      Set_Field (JSON_Object, Proc, GetProcessDataChannels);
      Set_Field (JSON_Object, Id, Trim (Sequence_Number'Img, Both));
      Set_Field (JSON_Object, "format", "JSON");
      Set_Field (Params, "device", Get_Value (Inverter));
      Set_Field (JSON_Object, "params", Params);
      return RPC & To_Wide_String (Write (JSON_Object));
   end Channels_Request;

   procedure Get_Inverter_Channels
     (Inv_Field_List : in out Inv_Field_Lists.Map;
      Sequence_Number : in out Sequence_Numbers;
      Next_Time : in out Time) is

      --  Populates Inv_Field_List keys with the channel names published by
      --  the configured inverter, retrying every Poll_Interval until
      --  successful or stopped.

      Label : constant String := "Channels";
      Reply : Unbounded_String;
      Reply_Time : Time;
      Status : Reply_Status;

      procedure Add_Channels (Reply : in Unbounded_String) is

         Parsed : constant Read_Result := Read (Reply);
         Proc_Value, Channels, Channel : JSON_Value;
         Channel_Array : JSON_Array;

         procedure Log_Rejected (Reason : in String) is

         begin -- Log_Rejected
            Put_Line ("Rejected - " & Reason);
            Put_Line (To_String (Reply));
         end Log_Rejected;

      begin -- Add_Channels
         if not Parsed.Success then
            Log_Rejected (Format_Parsing_Error (Parsed.Error));
            return;
         end if; -- not Parsed.Success
         Proc_Value := Field (Parsed.Value, Proc);
         if Kind (Proc_Value) /= JSON_String_Type or else
           To_String (Get (Proc_Value)) /= GetProcessDataChannels then
            Log_Rejected ("unexpected or missing proc");
            return;
         end if; -- Kind (Proc_Value) /= JSON_String_Type or else ...
         Channels :=
           Field (Field (Parsed.Value, "result"), Get_Value (Inverter));
         if Kind (Channels) /= JSON_Array_Type then
            Log_Rejected ("result/" & Get_Value (Inverter) &
                          " missing or not an array");
            return;
         end if; -- Kind (Channels) /= JSON_Array_Type
         Channel_Array := Get (Channels);
         for I in Natural range 1 .. Length (Channel_Array) loop
            Channel := Get (Channel_Array, I);
            if Kind (Channel) = JSON_String_Type then
               Include (Inv_Field_List, Unbounded_String'(Get (Channel)),
                        Inv_Fields'(others => <>));
            end if; -- Kind (Channel) = JSON_String_Type
         end loop; -- I in Natural range 1 .. Length (Channel_Array)
      end Add_Channels;

   begin -- Get_Inverter_Channels
      loop -- Channels request
         Send_Request (Sequence_Number, Channels_Request (Sequence_Number));
         Receive_Reply (Label, Sequence_Number, Reply, Reply_Time, Status);
         if Status = Valid then
            Add_Channels (Reply);
         end if; -- Status = Valid
         Sequence_Number := @ + 1;
         exit when Handlers.Signal_Stop or Ctrl_C_Stop;
         Next_Time := @ + Poll_Interval;
         delay until Next_Time;
         exit when not Is_Empty (Inv_Field_List);
      end loop; -- Channels request
      Put_Line ("Inverter " & Get_Value (Inverter) & " channels:" &
                Ada.Containers.Count_Type'Image (Length (Inv_Field_List)));
      for C in Inv_Field_List.Iterate loop
         Put_Line (To_String (Key (C)));
      end loop; -- C in Inv_Field_List.Iterate
   end Get_Inverter_Channels;

   function Process_Data_Request (Sequence_Number : in Sequence_Numbers;
                                  Inv_Field_List : in Inv_Field_Lists.Map)
                                  return Wide_String is

      RPC : constant Wide_String := "RPC=";
      JSON_Object : constant JSON_Value := Create_Object;
      Params : constant JSON_Value := Create_Object;
      Device : constant JSON_Value := Create_Object;
      Devices, Channels : JSON_Array := Empty_Array;

   begin -- Process_Data_Request
      Set_Field (JSON_Object, "version", "1.0");
      Set_Field (JSON_Object, Proc, GetProcessData);
      Set_Field (JSON_Object, Id, Trim (Sequence_Number'Img, Both));
      Set_Field (JSON_Object, "format", "JSON");
      for C in Inv_Field_List.Iterate loop
         Append (Channels, Create (Key (C)));
      end loop; -- C in Inv_Field_List.Iterate
      Set_Field (Device, "key", Get_Value (Inverter));
      Set_Field (Device, "channels", Channels);
      Append (Devices, Device);
      Set_Field (Params, "devices", Devices);
      Set_Field (JSON_Object, "params", Params);
      return RPC & To_Wide_String (Write (JSON_Object));
   end Process_Data_Request;

   procedure Get_Process_Data
     (Inv_Field_List : in out Inv_Field_Lists.Map;
      Sequence_Number : in out Sequence_Numbers) is

      --  Updates the values and units in Inv_Field_List for the configured
      --  inverter.

      Label : constant String := "Process data";
      Reply : Unbounded_String;
      Reply_Time : Time;
      Status : Reply_Status;

      procedure Update_Fields (Reply : in Unbounded_String) is

         Parsed : constant Read_Result := Read (Reply);
         Proc_Value, Devices, Device, Key_Value, Channels, Channel,
           Name_Value : JSON_Value;
         Device_Array, Channel_Array : JSON_Array;
         Device_Found : Boolean := False;

         procedure Log_Rejected (Reason : in String) is

         begin -- Log_Rejected
            Put_Line ("Rejected - " & Reason);
            Put_Line (To_String (Reply));
         end Log_Rejected;

         function Text (Value : in JSON_Value) return Unbounded_String is

            --  Value or unit as text, empty if absent.

         begin -- Text
            case Kind (Value) is
               when JSON_Null_Type =>
                  return Null_Unbounded_String;
               when JSON_String_Type =>
                  return Get (Value);
               when others =>
                  return To_Unbounded_String (Write (Value));
            end case; -- Kind (Value)
         end Text;

      begin -- Update_Fields
         if not Parsed.Success then
            Log_Rejected (Format_Parsing_Error (Parsed.Error));
            return;
         end if; -- not Parsed.Success
         Proc_Value := Field (Parsed.Value, Proc);
         if Kind (Proc_Value) /= JSON_String_Type or else
           To_String (Get (Proc_Value)) /= GetProcessData then
            Log_Rejected ("unexpected or missing proc");
            return;
         end if; -- Kind (Proc_Value) /= JSON_String_Type or else ...
         Devices := Field (Field (Parsed.Value, "result"), "devices");
         if Kind (Devices) /= JSON_Array_Type then
            Log_Rejected ("result/devices missing or not an array");
            return;
         end if; -- Kind (Devices) /= JSON_Array_Type
         Device_Array := Get (Devices);
         for I in Natural range 1 .. Length (Device_Array) loop
            Device := Get (Device_Array, I);
            Key_Value := Field (Device, "key");
            Channels := Field (Device, "channels");
            if Kind (Key_Value) = JSON_String_Type and then
              To_String (Get (Key_Value)) = Get_Value (Inverter) and then
              Kind (Channels) = JSON_Array_Type then
               Device_Found := True;
               Channel_Array := Get (Channels);
               for J in Natural range 1 .. Length (Channel_Array) loop
                  Channel := Get (Channel_Array, J);
                  Name_Value := Field (Channel, "meta");
                  --  meta is the channel name used by GetProcessDataChannels
                  if Kind (Name_Value) /= JSON_String_Type then
                     Name_Value := Field (Channel, "name");
                  end if; -- Kind (Name_Value) /= JSON_String_Type
                  if Kind (Name_Value) = JSON_String_Type then
                     Include (Inv_Field_List,
                              Unbounded_String'(Get (Name_Value)),
                              (Value => Text (Field (Channel, "value")),
                               Unit => Text (Field (Channel, "unit"))));
                  end if; -- Kind (Name_Value) = JSON_String_Type
               end loop; -- J in Natural range 1 .. Length (Channel_Array)
            end if; -- Kind (Key_Value) = JSON_String_Type and then ...
         end loop; -- I in Natural range 1 .. Length (Device_Array)
         if not Device_Found then
            Log_Rejected ("no channels for " & Get_Value (Inverter));
         end if; -- not Device_Found
      end Update_Fields;

   begin -- Get_Process_Data
      Send_Request (Sequence_Number,
                    Process_Data_Request (Sequence_Number, Inv_Field_List));
      Receive_Reply (Label, Sequence_Number, Reply, Reply_Time, Status);
      if Status = Valid then
         Update_Fields (Reply);
      end if; -- Status = Valid
      Sequence_Number := @ + 1;
   end Get_Process_Data;

   Next_Time : Time := Clock;
   Sequence_Number : Sequence_Numbers := Sequence_Numbers'First;
   Plant : Unbounded_String;
   Reply_Time : Time;
   Status : Reply_Status;
   Caller_Address : Sock_Addr_Type;
   Inv_Field_List : Inv_Field_Lists.Map := Inv_Field_Lists.Empty_Map;

begin -- Webbox_To_Mqtt
   Put_Line ("WebBox_to_MQTT version 20261025");
   if Configuration_File_Exists then
      Put_Line ("Reading " & Configuration_File);
      Read_Configuration;
   else
      raise JSON_Configuration_Error with "Missing configuration file " &
        Configuration_File;
   end if; -- Configuration_File_Exists

   Handlers.Install; -- Install Linux signal handlers
   Caller_Address := (Family => Family_Inet,
                      Addr => Any_Inet_Addr,
                      Port => Webbox_RPC_Port);
   Webbox_Address := (Family => Family_Inet,
                      Addr => Addresses (Get_Host_By_Name (Get_Value (WebBox)),
                      1),
                      Port => Webbox_RPC_Port);
   Create_Socket (Client_Socket, Family_Inet, Socket_Datagram); -- UDP socket
   Set_Socket_Option (Client_Socket, Socket_Level,
                      (Receive_Timeout, Reply_Timeout));
   Set_Socket_Option (Client_Socket, Socket_Level, (Reuse_Address, True));
   Bind_Socket (Client_Socket, Caller_Address);
   Connect_Tx (Broker_Host => Get_Value (Broker),
               User_Name => Get_Value (User),
               Password => Get_Value (Password),
               Topic => Get_Value (Topic),
               Handle => Publish_Handle);
   Get_Inverter_Channels (Inv_Field_List, Sequence_Number, Next_Time);
   while not (Handlers.Signal_Stop or Ctrl_C_Stop) loop -- Send request
      Send_Request (Sequence_Number, Overview_Request (Sequence_Number));
      Receive_Reply ("Plant", Sequence_Number, Plant, Reply_Time, Status);
      if Status = Valid then
         Publish (Reply_Time, Plant, Inv_Field_List, Publish_Handle);
      end if; -- Status = Valid
      Sequence_Number := @ + 1;
      --  Always incremented so that a late reply to a failed request is
      --  recognised as stale by the next request, whatever its proc.
      exit when Handlers.Signal_Stop or Ctrl_C_Stop;
      Next_Time := @ + Poll_Interval;
      delay until Next_Time;
      Get_Process_Data (Inv_Field_List, Sequence_Number);
      exit when Handlers.Signal_Stop or Ctrl_C_Stop;
      Next_Time := @ + Poll_Interval;
      delay until Next_Time;
   end loop; -- Send request
   Receiver.Stop;
   Handlers.Remove; -- Remove Linux signal handlers
   Close_Socket (Client_Socket);
   Disconnect (Publish_Handle);
   Set_Exit_Status (Ada.Command_Line.Success);
exception
   when E : others =>
      Put_Line ("Unhandled exception - " & Exception_Message (E));
   abort Receiver;
   Set_Exit_Status (Failure);
end Webbox_To_Mqtt;
