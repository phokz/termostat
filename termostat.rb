#!/usr/bin/ruby

require 'socket'
require 'bindata'

class CollectdString < BinData::Record
  endian :big
  uint16 :segment_type, :initial_value => 0
  uint16 :len, :value => lambda { name.length+5 }
  stringz :name
end

class CollectdSingle64BitNumber < BinData::Record
  endian :big
  uint16 :segment_type, :initial_value => 1
  uint16 :len, :initial_value => 12
  int64 :num
end

class CollectdGaugeValues < BinData::Record
  endian :big
  uint16 :segment_type
  uint16 :len
  uint16 :value_count
  int8 :value_type
  double_le :double_value
end


def packet_forge values

  result=""

  h = CollectdString.new    # host
  h.name = "phokz"
  result << h.to_binary_s

  values.each do |value|
    t = CollectdSingle64BitNumber.new
    t.num = value[:time]     # Time
    result << t.to_binary_s

    t = CollectdSingle64BitNumber.new
    t.segment_type = 7        # interval
    t.num = 10                # 10 sec
    result << t.to_binary_s

    h = CollectdString.new
    h.segment_type = 2        # plugin
    h.name = "teplota"
    result << h.to_binary_s

    h = CollectdString.new
    h.segment_type = 3        # plugin instance
    h.name = value[:instance]
    result << h.to_binary_s

    h = CollectdString.new
    h.segment_type = 4        # type
    h.name = "temperature"
    result << h.to_binary_s

    v = CollectdGaugeValues.new
    v.segment_type = 6
    v.len = 15
    v.value_count = 1
    v.value_type = 1
    v.double_value = value[:value]
    result << v.to_binary_s
  end

  UDPSocket.open.send(result, 0, '83.167.232.250', 25826)
  #  UDPSocket.open.send(result, 0, 'punk.hostim.name', 25826)
  #  puts "sending pkt!"
end

def sensor_name_by_serial string

  string.gsub!('B=','R=')
  string.gsub!('A=','R=')
  string.gsub!('R=28:A2:BB:F3:1:0:0:41','kuchyne prostor   ')
  string.gsub!('R=28:7B:69:B4:1:0:0:A8','koupelna prostor  ')
  string.gsub!('R=28:34:6B:B4:1:0:0:7A','koupelna _podlaha ')
  string.gsub!('R=28:D6:56:F3:1:0:0:33','chodba prostor    ')
  string.gsub!('R=28:1D:74:B4:1:0:0:49','pokoj _podlaha    ')
  string.gsub!('R=28:B:94:7D:2:0:0:34', 'pokoj prostor     ')
  string.gsub!('R=28:E3:7B:7D:2:0:0:9', 'kuchyne _podlaha  ')
  string.gsub!('R=28:CF:6F:F3:1:0:0:89','chodba _podlaha   ')
  string.gsub!('R=28:80:9E:7D:2:0:0:9B','dolni_ch_podlaha  ')
  string.gsub!('R=28:91:82:BA:3:0:0:BE','dolni_ch_prostor  ')
  string.strip
end

def log m
  ts=Time.now.strftime('%H:%M ')
  puts ts+m
  File.open('/tmp/logg','a') do |f|
    f.puts ts+m
  end
end

def relay(n,state,m='')
  if @relays[n] != state
    log("#{m} nr: #{n} to #{state}")
  end
  File.open("/dev/ttyUSB1","r+") do |f|
    f.print "*B1OS#{n}#{state}\r"
    s=""
    loop do
      a=f.getc
      s=s+a
      break if a.inspect=='"\r"'
    end

    #puts " #{n}: "+s.inspect

  end
  @relays[n]=state
  #else
  #  log("suppressing update #{ts} #{m} nr: #{n} to #{state}")
  #end
end

def switch_pumps
  left_circuit=[@relays[1],@relays[2],@relays[3],@relays[4]].join('')
  right_circuit=[@relays[6],@relays[7],@relays[8]].join('')

  if left_circuit=='LLLL'
    relay(12,'L','switching off left pump')
  else
    relay(12,'H','switching on left pump')
  end

  if right_circuit=='LLL'
    relay(10,'L','switching off right pump')
  else
    relay(10,'H','switching on right pump')
  end

end


def sensor_to_valve(sens)
  h={
    'chodba _podlaha' => 2,
    'pokoj _podlaha' => 1,
    'koupelna _podlaha' => 3,
    'kuchyne _podlaha' => 7,
    'dolni_ch_podlaha' => 8
  }
  return h[sens.strip]
end

def sensor_to_temp(sens)
  h={
    'chodba _podlaha' => 23,
    'pokoj _podlaha' => 30,
    'koupelna _podlaha' => 25,
    'kuchyne _podlaha' => 25,
    'dolni_ch_podlaha' => 24
  }
  return h[sens.strip]
end

def hysteresis
  return 0.5
end

def termos(s,t)
  valve=sensor_to_valve(s)
  if valve.nil?
    #log("#{s} nil temp")
    return
  end
  tt=sensor_to_temp(s)
#  log("#{s}: #{t} is between #{tt-hysteresis} and #{tt+hysteresis}")

  if t > (tt+hysteresis)
    relay(valve,'L',"switch off #{s} #{t} > #{tt+hysteresis}")
    switch_pumps
    #vypnout
    return
  end
  if t < (tt-hysteresis)
    relay(valve,'H',"switch on #{s} #{t} < #{tt-hysteresis}")
    switch_pumps
    #zapnout
    return
  end
end

@relays=(0..12).map{'X'}
relay(1,'L') # pokoj
relay(2,'L') # chodba
relay(3,'L') # koupelna
relay(4,'L') # koupelna zebrik
relay(6,'L') # loznice
relay(7,'L') # kuchyne
relay(8,'L') # chodba dol.



values=[]

File.open("/dev/ttyUSB0") do |f|

  while (line=f.gets) do
    key, t = line.split(' ')

    #puts line
    if key == 'Humidity:'
      hum, key, t = line.split(' ')
      key= 'koupelna_RH' if key=='0'
      key= 'pokoj_RH' if key=='1'
    end
    #puts key

    next if key == 'No'

    next if key == 'Humidity:'

    next if key.nil?

    sn = sensor_name_by_serial key

    next if t == '85.00'

    #    puts "                    #{sn} #{t}"
    termos(sn,t.to_f)

    values << {:instance => sn, :time => Time.now.to_i, :value => t.to_f}

    if values.size > 4
      packet_forge values
      values=[]
    end

  end
end

