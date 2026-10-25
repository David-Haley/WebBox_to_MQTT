--  Configuration interface between WebBox_to_MQTT and its configuration
--  program.

--  Author    : Devid Haley
--  Created   : 12/06/2026
--  Last_edit : 25/10/2026

--  20261025 : Inverter added.

package Common_Configuration is

   type Parameters is (WebBox, Inverter, Broker, User, Password, Topic);

   Configuration_File : constant String := "WebBox_to_MQTT_Configuration.json";

   function Encrypted (Parameter : Parameters) return Boolean;

end Common_Configuration;