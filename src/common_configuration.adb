--  Configuration interface between WebBox_to_MQTT and its configuration
--  program.

--  Author    : Devid Haley
--  Created   : 12/06/2026
--  Last_edit : 25/10/2026

--  20261025 : Inverter_Password added and requires encrypyion.

package body Common_Configuration is

   function Encrypted (Parameter : Parameters) return Boolean is
     (Parameter = Password or Parameter = Inverter_Password);

end Common_Configuration;