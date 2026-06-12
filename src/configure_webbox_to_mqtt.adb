--  Configuration program for WebBox_to_MQTT.

--  Author    : Devid Haley
--  Created   : 12/06/2026
--  Last_edit : 12/06/2026

with Ada.Text_IO; use Ada.Text_IO;
with Ada.Text_IO.Unbounded_IO; use Ada.Text_IO.Unbounded_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Common_Configuration; use Common_Configuration;
with DJH.JSON_Configuration;

procedure Configure_WebBox_to_MQTT is

   package Configuration is new
      DJH.JSON_Configuration (Parameters, Configuration_File, Encrypted);
   use Configuration;

   Editing : Boolean := False;
   Response : Character := 'Y';
   Value : Unbounded_String;
   
begin -- Configure_WebBox_to_MQTT
   Put_Line ("Configure_WebBox_to_MQTT version 20260612");
   if Configuration_File_Exists then
      Put_Line ("Configuration file" & Configuration_File & " found");
      Put_Line ("For each prompt either enter a new value or enter only to");
      Put_Line ("retain the existing value.");
      Read_Configuration;
      Editing := True;
   else
      Put_Line ("Configuration file " & Configuration_File & " not found");
      Put ("Create a new configuration file [y | n] : ");
      Get_Immediate (Response);
      if Response = 'y' or Response = 'Y' then
         Put_Line ("Values must be entered for each prompt.");
      end if; -- Response = 'y' or Response = 'Y'
   end if; -- Configuration_File_Exists
   if Response = 'y' or Response = 'Y' then
      for P in Parameters loop
         if Editing and not Encrypted (P) then
            Put_Line (P'Img & " """ & Get_Value (P) & """");
         end if; -- Editing and not Encrypted (P)
         Put (P'Img & ": ");
         Get_Line (Value);
         if Editing and Length (Value) = 0 then
            null;
         else
            Set_Value (P, To_String (Value));
         end if; -- Editing and Length (Value) = 0
      end loop; -- P in Parameters
      Write_Configuration;
   end if; -- Response = 'y' or Response = 'Y'
end Configure_WebBox_to_MQTT;