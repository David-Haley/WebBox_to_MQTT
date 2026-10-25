--  Configuration interface between WebBox_to_MQTT and its configuration
--  program.

--  Author    : Devid Haley
--  Created   : 12/06/2026
--  Last_edit : 24/10/2026

-- 20261018 : Inverter ans Inverter_Password added.

package Common_Configuration is

   type Parameters is (WebBox, Inverter, Inverter_Password, Broker, User, Password, Topic);

   Configuration_File : constant String := "WebBox_to_MQTT_Configuration.json";

   function Encrypted (Parameter : Parameters) return Boolean;

end Common_Configuration;