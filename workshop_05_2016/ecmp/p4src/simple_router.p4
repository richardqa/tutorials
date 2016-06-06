header_type ethernet_t {
    fields {
        dstAddr : 48;
        srcAddr : 48;
        etherType : 16;
    }
}
header_type ipv4_t {
    fields {
        version : 4;
        ihl : 4;
        diffserv : 8;
        totalLen : 16;
        identification : 16;
        flags : 3;
        fragOffset : 13;
        ttl : 8;
        protocol : 8;
        hdrChecksum : 16;
        srcAddr : 32;
        dstAddr: 32;
    }
}
header_type tcp_t {
    fields {
        srcPort : 16;
        dstPort : 16;
        seqNo : 32;
        ackNo : 32;
        dataOffset : 4;
        res : 3;
        ecn : 3;
        ctrl : 6;
        window : 16;
        checksum : 16;
        urgentPtr : 16;
    }
}
parser start {
    return parse_ethernet;
}
#define ETHERTYPE_IPV4 0x0800
header ethernet_t ethernet;
parser parse_ethernet {
    extract(ethernet);
    return select(latest.etherType) {
        ETHERTYPE_IPV4 : parse_ipv4;
        default: ingress;
    }
}
header ipv4_t ipv4;
field_list ipv4_checksum_list {
        ipv4.version;
        ipv4.ihl;
        ipv4.diffserv;
        ipv4.totalLen;
        ipv4.identification;
        ipv4.flags;
        ipv4.fragOffset;
        ipv4.ttl;
        ipv4.protocol;
        ipv4.srcAddr;
        ipv4.dstAddr;
}
field_list_calculation ipv4_checksum {
    input {
        ipv4_checksum_list;
    }
    algorithm : csum16;
    output_width : 16;
}
calculated_field ipv4.hdrChecksum  {
    verify ipv4_checksum;
    update ipv4_checksum;
}
#define IP_PROTOCOLS_TCP 6
parser parse_ipv4 {
    extract(ipv4);
    return select(latest.protocol) {
        IP_PROTOCOLS_TCP : parse_tcp;
        default: ingress;
    }
}
header tcp_t tcp;
parser parse_tcp {
    extract(tcp);
    return ingress;
}
action _drop() {
    drop();
}
header_type routing_metadata_t {
    fields {
        nhop_ipv4 : 32;
        // TODO: if you need extra metadata for ECMP, define it here
        // SOLUTION --->
        ecmp_offset : 14; // offset into the ecmp table
        // <--- SOLUTION
    }
}
metadata routing_metadata_t routing_metadata;
action set_nhop(nhop_ipv4, port) {
    modify_field(routing_metadata.nhop_ipv4, nhop_ipv4);
    modify_field(standard_metadata.egress_spec, port);
    add_to_field(ipv4.ttl, -1);
}
#define ECMP_BIT_WIDTH 10
#define ECMP_GROUP_TABLE_SIZE 1024
#define ECMP_NHOP_TABLE_SIZE 16384
field_list l3_hash_fields {
    ipv4.srcAddr;
    ipv4.dstAddr;
    ipv4.protocol;
    tcp.srcPort;
    tcp.dstPort;
}
field_list_calculation ecmp_hash {
    input {
        l3_hash_fields;
    }
    algorithm : crc16;
    output_width : ECMP_BIT_WIDTH;
}
action set_ecmp_select(ecmp_base, ecmp_count) {
    modify_field_with_hash_based_offset(routing_metadata.ecmp_offset, ecmp_base,
                                        ecmp_hash, ecmp_count);
}
table ecmp_group {
    reads {
        ipv4.dstAddr : lpm;
    }
    actions {
        _drop;
        set_ecmp_select;
    }
    size : ECMP_GROUP_TABLE_SIZE;
}
table ecmp_nhop {
    reads {
        routing_metadata.ecmp_offset : exact;
    }
    actions {
        _drop;
        set_nhop;
    }
    size : ECMP_NHOP_TABLE_SIZE;
}
action set_dmac(dmac) {
    modify_field(ethernet.dstAddr, dmac);
}
table forward {
    reads {
        routing_metadata.nhop_ipv4 : exact;
    }
    actions {
        set_dmac;
        _drop;
    }
    size: 512;
}
action rewrite_mac(smac) {
    modify_field(ethernet.srcAddr, smac);
}
table send_frame {
    reads {
        standard_metadata.egress_port: exact;
    }
    actions {
        rewrite_mac;
        _drop;
    }
    size: 256;
}
control ingress {
    if(valid(ipv4) and ipv4.ttl > 0) {
        apply(ecmp_group);
        apply(ecmp_nhop);
        apply(forward);
    }
}
control egress {
    apply(send_frame);
}
