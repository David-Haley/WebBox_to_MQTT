# WebBox_to_MQTT
This repososttory contains a program that reads from an SMA WebBox via a remmote procedure call and publishes to a MQTT Broker.

The webbox host name, topic to publish, host name of the broker, user name and password are read from the command line. The published topic contains tthe a UTC time stamp, the current plant power output and daily yield. The topic is published at 30 s intervals, the maximum rate recommended in the SMA manual.
