/*
Copyright 2023 Intel Corporation

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#include <core.p4>
#include "../pna.p4"

extern DirectRegister<T> {
  DirectRegister();
  T read();
  void write(in T value);
}

typedef bit<48>  EthernetAddress;

typedef bit<8>  type1_t;
typedef bit<16> type2_t;
typedef bit<24> type3_t;

header ethernet_t {
    EthernetAddress dstAddr;
    EthernetAddress srcAddr;
    bit<16>         etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

struct empty_metadata_t {
}

typedef bit<48> ByteCounter_t;
typedef bit<32> PacketCounter_t;
typedef bit<80> PacketByteCounter_t;

const bit<32> NUM_PORTS = 4;


struct main_metadata_t {
}

struct headers_t {
    ethernet_t ethernet;
    ipv4_t ipv4;
}

parser MainParserImpl(
    packet_in pkt,
    out   headers_t       hdr,
    inout main_metadata_t main_meta,
    in    pna_main_parser_input_metadata_t istd)
{
    state start {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition accept;
    }
}


control MainControlImpl(
    inout headers_t       hdr,
    inout main_metadata_t user_meta,
    in    pna_main_input_metadata_t  istd,
    inout pna_main_output_metadata_t ostd)
{
    type1_t tmp;
    
    DirectRegister<type1_t>() r1;
    DirectRegister<type2_t>() r2;

    // Because a1 can only access r1 and r2, but never r3
    // (straightforward to analyze at compile time in P4 compiler),
    // back end is free NOT to allocate storage for r3 in table
    // entries that have action a1.
    action a1(type1_t p1) {
        type1_t v1;
        type2_t v2;
        v1 = r1.read() + p1;
        v2 = r2.read();
        if (hdr.ipv4.protocol == 17) {
            v2 = v2 + hdr.ipv4.totalLen;
        } else {
            v2 = v2 + hdr.ipv4.identification;
        }
        r1.write(v1);
        r2.write(v2);
    }

    // Because a2 can only access r1, but never r2 nor r3, target only
    // needs to allocate space for r1 in table entries with action a2.
    action a2() {
        tmp = tmp + r1.read();
        r1.write(tmp);
    }

    // Because a3 access none of r1, nor r2, nor r3, target need not
    // allocate space to store any of them in table entries with
    // action a3.
    action a3(PortId_t p) {
        send_to_port(p);
    }

    table t1 {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            a1;
            a2;
            a3;
        }
#ifdef P4C_SUPPORTS_NEW_TABLE_PROPERTY_REGISTERS
        registers = { r1; r2; r3; }
#endif
    }
    apply {
        if (hdr.ipv4.isValid()) {
            tmp = (type1_t) hdr.ipv4.totalLen;
            t1.apply();
            hdr.ipv4.identification = (bit<16>) tmp;
        }
    }
}

control MainDeparserImpl(
    packet_out pkt,
    in    headers_t hdr,
    in    main_metadata_t user_meta,
    in    pna_main_output_metadata_t ostd)
{
    apply {
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
    }
}

PNA_NIC(
    MainParserImpl(),
    MainControlImpl(),
    MainDeparserImpl()
    ) main;
