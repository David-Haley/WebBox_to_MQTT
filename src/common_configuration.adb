--  Configuration interface between WebBox_to_MQTT and its configuration
--  program.

--  Author    : Devid Haley
--  Created   : 12/06/2026
--  Last_edit : 12/06/2026

package body Common_Configuration is

   function Encrypted (Parameter : Parameters) return Boolean is
     (Parameter = Password);

end Common_Configuration;