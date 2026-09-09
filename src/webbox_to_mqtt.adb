--  This program is intended to be run as a service publishing the results
--  from remote procedure calls to a SMA WebBox.

--  Author    : David Haley
--  Created   : 19/04/2026
--  Last Edit : 09/09/2026

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
with GNAT.Sockets; use GNAT.Sockets;
with GNATCOLL.JSON; use GNATCOLL.JSON;
with DJH.JSON_Configuration;
with Linux_Signals; use Linux_Signals;
with MQTT_Client; use MQTT_Client;
with Common_Configuration; use Common_Configuration;

procedure Webbox_To_Mqtt is

   Webbox_RPC_Port : constant Port_Type := 34268;

   --  Webbox JSON identifiers
   Proc : constant String := "proc";
   GetPlantOverview : constant String := "GetPlantOverview";
   Id : constant String := "id";

   package Configuration is new
      DJH.JSON_Configuration (Parameters, Configuration_File, Encrypted);
   use Configuration; 

   procedure Publish (Sequence_Number : in Positive;
                      Reply_Time : in Time;
                      JSON_String : in String;
                      Publish_Handle : in MQTT_Handle) is

      Parsed : Read_Result;
      Id_Value, Proc_Value, Result, Overview, Entry_Object,
        Name_Value, Value_Value : JSON_Value;
      Data_Array : JSON_Array;
      Valid, Power_Found, Yield_Found : Boolean := False;
      Clock_JSON : constant JSON_Value := Create_Object;

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

      procedure Log_Rejected (Reason : in String) is
      begin -- Log_Rejected
         Put_Line ("Sequence" & Sequence_Number'Img & " rejected - " &
                     Reason);
         Put_Line (JSON_String);
      end Log_Rejected;

   begin -- Publish
      Parsed := Read (JSON_String);
      if not Parsed.Success then
         Put_Line (JSON_String);
         Put_Line (Format_Parsing_Error (Parsed.Error));
         return;
      end if; -- not Parsed.Success
      Id_Value := Field (Parsed.Value, Id);
      if Kind (Id_Value) /= JSON_String_Type then
         Log_Rejected ("id field missing or not a string");
         return;
      end if; -- Kind (Id_Value) /= JSON_String_Type
      begin -- Sequence_Number parse block
         Valid := Sequence_Number =
           Positive'Value (To_String (Get (Id_Value)));
      exception
         when Constraint_Error =>
            Log_Rejected ("id is not a valid sequence number");
            return;
      end; -- Sequence_Number parse block
      if not Valid then
         Log_Rejected ("sequence number mismatch");
         return;
      end if; -- not Valid
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
      Set_Field (Clock_JSON, "message_time_utc", Image (Reply_Time));
      Send (Publish_Handle, Write (Clock_JSON));
   end Publish;

   --  Global variables used by Receiver and main program
      Client_Socket : Socket_Type;
      Publish_Handle : MQTT_Handle;

   task Receiver is
      entry Request_Sent (Sequence_Number : in Positive);
      entry Stop;
   end Receiver;

   task body Receiver is

      Rx_Buffer_Length : constant Stream_Element_Offset := 1024;
      --  The expected reply length is around 850 bytes (from WireShark
      --  testing), some margin of safety has been applied.
      Rx_Buffer : Stream_Element_Array (1 .. Rx_Buffer_Length);
      Rx_Wide_JSON : Wide_String (1 .. Positive (Rx_Buffer_Length / 2));
      for Rx_Wide_JSON'Address use Rx_Buffer'Address;
      pragma Import (Ada, Rx_Wide_JSON);
      Last : Stream_Element_Offset;

      Run : Boolean := True;

   begin -- Receiver
      while Run loop
         select
            accept Request_Sent (Sequence_Number : in Positive) do
               begin -- Receive exception block
                  Receive_Socket (Client_Socket, Rx_Buffer, Last);
                  declare -- JSON_String declaration block
                     Reply_Time : constant Time := Clock;
                     JSON_String : constant String :=
                       To_String (Rx_Wide_JSON (1 .. Positive (Last / 2)));
                  begin -- JSON_String declaration block
                     Publish (Sequence_Number, Reply_Time, JSON_String,
                              Publish_Handle);
                  end; -- JSON_String declaration block
               exception
                  when E : Socket_Error =>
                     if Resolve_Exception (E) /=
                       Resource_Temporarily_Unavailable then
                        Put_Line ("Sequence" & Sequence_Number'Img &
                                    " receive error - " &
                                    Exception_Message (E));
                     end if; -- Resolve_Exception (E) /= ...
                     --  Resource_Temporarily_Unavailable is the expected
                     --  Receive_Socket timeout (SO_RCVTIMEO), silently
                     --  ignored; any other socket error is logged.
                  when E : others =>
                     Put_Line ("Sequence" & Sequence_Number'Img &
                                 " unexpected error - " &
                                 Exception_Information (E));
                     --  Logged rather than swallowed so a JSON/parsing bug
                     --  is visible instead of silently dropping the reply.
               end; -- Receive exception block
            end Request_Sent;
         or
            accept Stop do
               Run := False;
            end Stop;
         end select;
      end loop; -- Run
   end Receiver;

   function Overview_Request (Sequence_Number : in Positive)
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

   Poll_Interval : constant Duration := 30.0; -- Minimum recommended 30 s
   Next_Time : Time := Clock;
   Sequence_Number : Positive := Positive'First;
   Webbox_Address, Caller_Address : Sock_Addr_Type;

begin -- Webbox_To_Mqtt
   Put_Line ("WebBox_to_MQTT version 20260909");
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
   Set_Socket_Option (Client_Socket, Socket_Level, (Receive_Timeout, 5.0));
   --  Should be an absolute eternity, typical time to reply was 300 ms in
   --  WireShark testing;
   Set_Socket_Option (Client_Socket, Socket_Level, (Reuse_Address, True));
   Bind_Socket (Client_Socket, Caller_Address);
   Connect_Tx (Broker_Host => Get_Value (Broker),
               User_Name => Get_Value (User),
               Password => Get_Value (Password), 
               Topic => Get_Value (Topic),
               Handle => Publish_Handle);
   loop -- Send request
      declare -- Tx block
         Request : Wide_String := Overview_Request (Sequence_Number);
         Tx_Buffer_Length : constant Stream_Element_Offset :=
           Request'Size / Stream_Element'Size;
         Tx_Buffer : Stream_Element_Array (1 .. Tx_Buffer_Length);
         for Tx_Buffer'Address use Request'Address;
         pragma Import (Ada, Tx_Buffer);

         Last : Stream_Element_Offset;

      begin -- Tx block
         Send_Socket (Client_Socket, Tx_Buffer, Last, Webbox_Address);
         Receiver.Request_Sent (Sequence_Number);
      exception
         when E : others =>
            Put_Line ("TX sequence:" & Sequence_Number'Img & " - " &
                      Exception_Message (E));
      end; -- Tx block
      Sequence_Number := @ + 1;
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
