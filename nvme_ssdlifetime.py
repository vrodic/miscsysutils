#!/usr/bin/env python 

#sudo nvme smart-log /dev/nvme0
import fileinput

# get this somehow, this is for 970 Pro 512 GB found here
# https://www.samsung.com/semiconductor/minisite/ssd/product/consumer/970pro/
write_endurance = 600 *1024 *1024 *1024 *1024.0
for line in fileinput.input():
    line = line.rstrip()
    # data_units_written                  : 499.055
    
    if line.startswith('data_units_written'):
        # https://www.percona.com/blog/2017/02/09/using-nvme-command-line-tools-to-check-nvme-flash-health/
        bytes_written = int(line.split(':')[1].strip().replace('.',''))*512000
        percent_write_used = (bytes_written/write_endurance)*100
        print percent_write_used
    #print line
    pass