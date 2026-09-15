# S3 - a link that drops and returns inside the check window must NOT cost a
# captive portal. This is what WIFI_CHECK_TIMEOUT is for.
describe "S3  brief flap is debounced, no portal"
fixture_sysfs eth0:physical wlan0:wireless lo:virtual
fixture_ip
fixture_iwgetid "Deep Runner-IOT" --drop-after 1 --return-after 2
run_start_sh --passes 3 WIFI_CHECK_TIMEOUT=6
refute_launched
