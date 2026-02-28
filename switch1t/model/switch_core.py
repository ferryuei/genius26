"""
1.2Tbps 48×25G 二层网络交换机核心 Python仿真实现
版本: v1.2
"""

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set, Tuple
from enum import Enum, auto
from collections import deque
import time
import hashlib
import struct

# ============================================================================
# 常量定义
# ============================================================================

NUM_PORTS = 48                  # 端口数量
PORT_SPEED_GBPS = 25            # 单端口速率 (Gbps)
TOTAL_BANDWIDTH_TBPS = 1.2      # 总带宽 (Tbps)

CELL_SIZE = 128                 # Cell大小 (Bytes)
TOTAL_CELLS = 64 * 1024         # 总Cell数 (64K)
BUFFER_SIZE_MB = 8              # 缓冲区大小 (MB)
NUM_BANKS = 16                  # 内存Bank数量
NUM_FREE_POOLS = 4              # 空闲池数量

MAC_TABLE_SIZE = 32 * 1024      # MAC表容量 (32K)
MAC_TABLE_WAYS = 4              # 4路组相联
MAC_TABLE_SETS = MAC_TABLE_SIZE // MAC_TABLE_WAYS

NUM_QUEUES_PER_PORT = 8         # 每端口队列数
TOTAL_QUEUES = NUM_PORTS * NUM_QUEUES_PER_PORT

MAX_PACKET_SIZE = 16 * 1024     # 最大包长 (16KB)
MIN_PACKET_SIZE = 64            # 最小包长 (64B)

VLAN_MAX = 4096                 # 最大VLAN数
ACL_TABLE_SIZE = 1024           # ACL表容量

MAC_AGING_TIME = 300            # MAC老化时间 (秒)


# ============================================================================
# 枚举类型
# ============================================================================

class ForwardMode(Enum):
    """转发模式"""
    STORE_AND_FORWARD = auto()
    CUT_THROUGH = auto()


class QueueState(Enum):
    """队列状态"""
    EMPTY = 0
    NORMAL = 1
    CONGESTED = 2
    BLOCKED = 3


class VlanAction(Enum):
    """VLAN动作"""
    NONE = 0
    PUSH = 1
    POP = 2
    SWAP = 3


class AclAction(Enum):
    """ACL动作"""
    PERMIT = auto()
    DENY = auto()
    MIRROR = auto()
    RATE_LIMIT = auto()


class PortState(Enum):
    """端口STP状态"""
    DISABLED = auto()
    BLOCKING = auto()
    LEARNING = auto()
    FORWARDING = auto()


# ============================================================================
# 数据结构定义
# ============================================================================

@dataclass
class CellMetadata:
    """
    Cell元数据 (32bit)
    - next_ptr: 16bit, 下一个Cell指针
    - ref_cnt: 3bit, 引用计数
    - eop: 1bit, 报文结束标记
    - valid: 1bit, 有效标记
    """
    next_ptr: Optional[int] = None  # 16bit, 指向下一个Cell
    ref_cnt: int = 0                # 3bit, 引用计数 (组播)
    eop: bool = False               # 1bit, End of Packet
    valid: bool = False             # 1bit, 有效标记


@dataclass
class PacketDescriptor:
    """
    报文描述符 (128bit)
    """
    head_ptr: int = 0               # 16bit, 首Cell指针
    tail_ptr: int = 0               # 16bit, 尾Cell指针
    cell_count: int = 0             # 7bit, Cell数量
    pkt_len: int = 0                # 14bit, 报文长度
    src_port: int = 0               # 6bit, 源端口
    dst_port: int = 0               # 6bit, 目的端口
    queue_id: int = 0               # 3bit, 目的队列
    multicast: bool = False         # 1bit, 组播标记
    mc_group_id: int = 0            # 8bit, 组播组ID
    vlan_action: VlanAction = VlanAction.NONE  # 2bit
    new_vid: int = 0                # 12bit, 新VLAN ID
    new_pcp: int = 0                # 3bit, 新PCP
    timestamp: int = 0              # 16bit, 入队时间戳
    drop_eligible: bool = False     # 1bit, 可丢弃标记
    # 链表指针 (用于队列)
    next_desc: Optional[int] = None


@dataclass
class QueueDescriptor:
    """
    队列描述符 (64bit)
    """
    head: Optional[int] = None      # 16bit, 队列头
    tail: Optional[int] = None      # 16bit, 队列尾
    length: int = 0                 # 16bit, 队列深度 (Cell数)
    state: QueueState = QueueState.EMPTY
    # 统计
    enqueue_count: int = 0
    dequeue_count: int = 0
    drop_count: int = 0


@dataclass 
class MacEntry:
    """
    MAC表条目 (72bit)
    """
    mac_addr: bytes = b'\x00' * 6   # 48bit, MAC地址
    vid: int = 0                    # 12bit, VLAN ID
    port: int = 0                   # 6bit, 端口号
    static: bool = False            # 1bit, 静态条目
    age: int = 3                    # 2bit, 老化计数器
    valid: bool = False             # 1bit, 有效标记


@dataclass
class AclRule:
    """ACL规则"""
    src_port_mask: int = 0xFFFFFFFFFFFF  # 源端口掩码
    src_port: int = 0
    dmac_mask: bytes = b'\xff' * 6
    dmac: bytes = b'\x00' * 6
    smac_mask: bytes = b'\xff' * 6  
    smac: bytes = b'\x00' * 6
    vid_mask: int = 0xFFF
    vid: int = 0
    ethertype_mask: int = 0xFFFF
    ethertype: int = 0
    action: AclAction = AclAction.PERMIT
    priority: int = 0
    valid: bool = False


@dataclass
class Packet:
    """以太网报文"""
    dmac: bytes = b'\x00' * 6
    smac: bytes = b'\x00' * 6
    vid: int = 0                    # VLAN ID (0表示无VLAN)
    pcp: int = 0                    # Priority Code Point
    ethertype: int = 0x0800
    payload: bytes = b''
    
    @property
    def length(self) -> int:
        base_len = 14  # DMAC(6) + SMAC(6) + EtherType(2)
        if self.vid > 0:
            base_len += 4  # VLAN Tag
        return base_len + len(self.payload)
    
    def serialize(self) -> bytes:
        """序列化报文"""
        data = self.dmac + self.smac
        if self.vid > 0:
            # 802.1Q VLAN Tag
            tci = (self.pcp << 13) | self.vid
            data += struct.pack('>HH', 0x8100, tci)
        data += struct.pack('>H', self.ethertype)
        data += self.payload
        return data


@dataclass
class PortConfig:
    """端口配置"""
    enabled: bool = True
    state: PortState = PortState.FORWARDING
    default_vid: int = 1
    default_pcp: int = 0
    forward_mode: ForwardMode = ForwardMode.STORE_AND_FORWARD
    # 速率限制
    ingress_rate_limit: int = 0     # 0表示不限制, 单位Mbps
    egress_rate_limit: int = 0
    # 统计
    rx_packets: int = 0
    rx_bytes: int = 0
    tx_packets: int = 0
    tx_bytes: int = 0
    rx_drops: int = 0
    tx_drops: int = 0


# ============================================================================
# 内存管理模块
# ============================================================================

class CellAllocator:
    """
    Cell分配器
    - 管理64K个128B Cells
    - 4个并行空闲池
    """
    
    def __init__(self):
        # Cell数据存储 (实际硬件为SRAM)
        self.cell_data: List[bytearray] = [
            bytearray(CELL_SIZE) for _ in range(TOTAL_CELLS)
        ]
        # Cell元数据
        self.cell_meta: List[CellMetadata] = [
            CellMetadata() for _ in range(TOTAL_CELLS)
        ]
        # 4个空闲池
        self.free_pools: List[deque] = [deque() for _ in range(NUM_FREE_POOLS)]
        self.free_counts: List[int] = [0] * NUM_FREE_POOLS
        
        # 初始化: 将Cells均分到4个池
        cells_per_pool = TOTAL_CELLS // NUM_FREE_POOLS
        for i in range(TOTAL_CELLS):
            pool_id = i // cells_per_pool
            if pool_id >= NUM_FREE_POOLS:
                pool_id = NUM_FREE_POOLS - 1
            self.free_pools[pool_id].append(i)
            self.free_counts[pool_id] += 1
        
        # 统计
        self.alloc_count = 0
        self.free_count = 0
    
    def allocate(self, pool_hint: int = 0) -> Optional[int]:
        """
        分配一个Cell
        Args:
            pool_hint: 优先使用的池ID
        Returns:
            Cell ID, 或None如果分配失败
        """
        # 尝试从指定池分配
        pool_id = pool_hint % NUM_FREE_POOLS
        
        for _ in range(NUM_FREE_POOLS):
            if self.free_counts[pool_id] > 0:
                cell_id = self.free_pools[pool_id].popleft()
                self.free_counts[pool_id] -= 1
                # 初始化元数据
                self.cell_meta[cell_id] = CellMetadata(valid=True)
                self.alloc_count += 1
                return cell_id
            pool_id = (pool_id + 1) % NUM_FREE_POOLS
        
        return None  # 所有池都空了
    
    def free(self, cell_id: int) -> bool:
        """
        释放一个Cell
        """
        if cell_id < 0 or cell_id >= TOTAL_CELLS:
            return False
        
        meta = self.cell_meta[cell_id]
        if not meta.valid:
            return False
        
        # 引用计数处理 (组播)
        if meta.ref_cnt > 0:
            meta.ref_cnt -= 1
            if meta.ref_cnt > 0:
                return True  # 还有其他引用
        
        # 真正释放
        meta.valid = False
        meta.next_ptr = None
        meta.eop = False
        
        # 归还到原池
        pool_id = cell_id % NUM_FREE_POOLS
        self.free_pools[pool_id].append(cell_id)
        self.free_counts[pool_id] += 1
        self.free_count += 1
        
        return True
    
    def write_cell(self, cell_id: int, data: bytes, offset: int = 0) -> bool:
        """写入Cell数据"""
        if cell_id < 0 or cell_id >= TOTAL_CELLS:
            return False
        if offset + len(data) > CELL_SIZE:
            return False
        
        self.cell_data[cell_id][offset:offset+len(data)] = data
        return True
    
    def read_cell(self, cell_id: int) -> Optional[bytes]:
        """读取Cell数据"""
        if cell_id < 0 or cell_id >= TOTAL_CELLS:
            return None
        if not self.cell_meta[cell_id].valid:
            return None
        return bytes(self.cell_data[cell_id])
    
    def get_free_count(self) -> int:
        """获取空闲Cell总数"""
        return sum(self.free_counts)
    
    def link_cells(self, cell_id: int, next_cell_id: int):
        """链接两个Cell"""
        if 0 <= cell_id < TOTAL_CELLS:
            self.cell_meta[cell_id].next_ptr = next_cell_id
    
    def set_eop(self, cell_id: int):
        """设置报文结束标记"""
        if 0 <= cell_id < TOTAL_CELLS:
            self.cell_meta[cell_id].eop = True
    
    def increment_ref(self, cell_id: int, count: int = 1):
        """增加引用计数 (用于组播)"""
        if 0 <= cell_id < TOTAL_CELLS:
            self.cell_meta[cell_id].ref_cnt += count


class PacketBuffer:
    """
    报文缓冲区管理
    - 将报文存储到Cell链表
    - 管理报文描述符
    """
    
    def __init__(self, cell_allocator: CellAllocator):
        self.cell_alloc = cell_allocator
        # 报文描述符池
        self.descriptors: List[PacketDescriptor] = [
            PacketDescriptor() for _ in range(4096)
        ]
        self.desc_free_list: deque = deque(range(4096))
        # 统计
        self.store_count = 0
        self.retrieve_count = 0
    
    def store_packet(self, packet: Packet, src_port: int) -> Optional[int]:
        """
        存储报文到缓冲区
        Returns:
            描述符ID, 或None如果存储失败
        """
        if not self.desc_free_list:
            return None
        
        # 序列化报文
        pkt_data = packet.serialize()
        pkt_len = len(pkt_data)
        
        # 计算需要的Cell数
        num_cells = (pkt_len + CELL_SIZE - 1) // CELL_SIZE
        
        # 分配Cells
        cell_ids = []
        for i in range(num_cells):
            cell_id = self.cell_alloc.allocate(pool_hint=src_port)
            if cell_id is None:
                # 分配失败，回滚
                for cid in cell_ids:
                    self.cell_alloc.free(cid)
                return None
            cell_ids.append(cell_id)
        
        # 写入数据并链接Cells
        for i, cell_id in enumerate(cell_ids):
            start = i * CELL_SIZE
            end = min(start + CELL_SIZE, pkt_len)
            self.cell_alloc.write_cell(cell_id, pkt_data[start:end])
            
            if i < len(cell_ids) - 1:
                self.cell_alloc.link_cells(cell_id, cell_ids[i + 1])
            else:
                self.cell_alloc.set_eop(cell_id)
        
        # 创建描述符
        desc_id = self.desc_free_list.popleft()
        desc = self.descriptors[desc_id]
        desc.head_ptr = cell_ids[0]
        desc.tail_ptr = cell_ids[-1]
        desc.cell_count = num_cells
        desc.pkt_len = pkt_len
        desc.src_port = src_port
        desc.timestamp = int(time.time() * 1000) & 0xFFFF
        
        self.store_count += 1
        return desc_id
    
    def retrieve_packet(self, desc_id: int) -> Optional[bytes]:
        """
        从缓冲区读取报文
        """
        if desc_id < 0 or desc_id >= len(self.descriptors):
            return None
        
        desc = self.descriptors[desc_id]
        if desc.cell_count == 0:
            return None
        
        # 遍历Cell链表读取数据
        data = bytearray()
        cell_id = desc.head_ptr
        remaining = desc.pkt_len
        
        while cell_id is not None and remaining > 0:
            cell_data = self.cell_alloc.read_cell(cell_id)
            if cell_data is None:
                break
            
            read_len = min(CELL_SIZE, remaining)
            data.extend(cell_data[:read_len])
            remaining -= read_len
            
            meta = self.cell_alloc.cell_meta[cell_id]
            cell_id = meta.next_ptr
        
        self.retrieve_count += 1
        return bytes(data)
    
    def release_packet(self, desc_id: int) -> bool:
        """
        释放报文占用的资源
        """
        if desc_id < 0 or desc_id >= len(self.descriptors):
            return False
        
        desc = self.descriptors[desc_id]
        if desc.cell_count == 0:
            return False
        
        # 释放所有Cells
        cell_id = desc.head_ptr
        while cell_id is not None:
            meta = self.cell_alloc.cell_meta[cell_id]
            next_id = meta.next_ptr
            self.cell_alloc.free(cell_id)
            cell_id = next_id
        
        # 重置描述符并归还
        self.descriptors[desc_id] = PacketDescriptor()
        self.desc_free_list.append(desc_id)
        
        return True
    
    def get_descriptor(self, desc_id: int) -> Optional[PacketDescriptor]:
        """获取描述符"""
        if 0 <= desc_id < len(self.descriptors):
            return self.descriptors[desc_id]
        return None


# ============================================================================
# MAC查表引擎
# ============================================================================

class MacTable:
    """
    MAC地址表
    - 32K条目, 4路组相联
    - Hash + SRAM
    """
    
    def __init__(self):
        # 4路组相联表
        self.table: List[List[MacEntry]] = [
            [MacEntry() for _ in range(MAC_TABLE_WAYS)]
            for _ in range(MAC_TABLE_SETS)
        ]
        # 学习队列
        self.learn_queue: deque = deque(maxlen=512)
        # 学习速率限制 (每端口)
        self.learn_count_per_port: List[int] = [0] * NUM_PORTS
        self.last_learn_reset: float = time.time()
        # 统计
        self.lookup_count = 0
        self.hit_count = 0
        self.miss_count = 0
        self.learn_count = 0
    
    def _compute_hash(self, mac: bytes, vid: int) -> int:
        """计算Hash索引"""
        # CRC16(MAC) XOR VID
        data = mac + struct.pack('>H', vid)
        crc = int.from_bytes(hashlib.md5(data).digest()[:2], 'big')
        return (crc ^ vid) % MAC_TABLE_SETS
    
    def lookup(self, mac: bytes, vid: int) -> Optional[int]:
        """
        查找MAC地址
        Returns:
            端口号, 或None如果未找到
        """
        self.lookup_count += 1
        set_idx = self._compute_hash(mac, vid)
        
        for way in range(MAC_TABLE_WAYS):
            entry = self.table[set_idx][way]
            if entry.valid and entry.mac_addr == mac and entry.vid == vid:
                # 命中，更新老化计数器
                entry.age = 3
                self.hit_count += 1
                return entry.port
        
        self.miss_count += 1
        return None
    
    def learn(self, mac: bytes, vid: int, port: int) -> bool:
        """
        学习MAC地址
        """
        # 检查学习速率限制
        current_time = time.time()
        if current_time - self.last_learn_reset > 1.0:
            # 重置每秒计数
            self.learn_count_per_port = [0] * NUM_PORTS
            self.last_learn_reset = current_time
        
        if self.learn_count_per_port[port] >= 1000:
            return False  # 超过速率限制
        
        set_idx = self._compute_hash(mac, vid)
        
        # 查找空闲或可替换的条目
        target_way = None
        min_age = 4
        
        for way in range(MAC_TABLE_WAYS):
            entry = self.table[set_idx][way]
            
            # 已存在则更新
            if entry.valid and entry.mac_addr == mac and entry.vid == vid:
                entry.port = port
                entry.age = 3
                return True
            
            # 找空闲条目
            if not entry.valid:
                target_way = way
                break
            
            # 找最老的条目 (用于替换)
            if not entry.static and entry.age < min_age:
                min_age = entry.age
                target_way = way
        
        if target_way is None:
            return False  # 无法学习
        
        # 写入新条目
        entry = self.table[set_idx][target_way]
        entry.mac_addr = mac
        entry.vid = vid
        entry.port = port
        entry.static = False
        entry.age = 3
        entry.valid = True
        
        self.learn_count += 1
        self.learn_count_per_port[port] += 1
        
        return True
    
    def add_static(self, mac: bytes, vid: int, port: int) -> bool:
        """添加静态MAC条目"""
        set_idx = self._compute_hash(mac, vid)
        
        for way in range(MAC_TABLE_WAYS):
            entry = self.table[set_idx][way]
            if not entry.valid or (entry.mac_addr == mac and entry.vid == vid):
                entry.mac_addr = mac
                entry.vid = vid
                entry.port = port
                entry.static = True
                entry.age = 3
                entry.valid = True
                return True
        
        return False
    
    def delete(self, mac: bytes, vid: int) -> bool:
        """删除MAC条目"""
        set_idx = self._compute_hash(mac, vid)
        
        for way in range(MAC_TABLE_WAYS):
            entry = self.table[set_idx][way]
            if entry.valid and entry.mac_addr == mac and entry.vid == vid:
                entry.valid = False
                return True
        
        return False
    
    def age_entries(self):
        """老化扫描"""
        for set_idx in range(MAC_TABLE_SETS):
            for way in range(MAC_TABLE_WAYS):
                entry = self.table[set_idx][way]
                if entry.valid and not entry.static:
                    entry.age -= 1
                    if entry.age <= 0:
                        entry.valid = False
    
    def get_entry_count(self) -> int:
        """获取有效条目数"""
        count = 0
        for set_idx in range(MAC_TABLE_SETS):
            for way in range(MAC_TABLE_WAYS):
                if self.table[set_idx][way].valid:
                    count += 1
        return count


# ============================================================================
# VLAN表
# ============================================================================

class VlanTable:
    """VLAN配置表"""
    
    def __init__(self):
        # VLAN成员端口位图
        self.member_ports: Dict[int, Set[int]] = {}
        # VLAN未标记端口 (egress时去除tag)
        self.untagged_ports: Dict[int, Set[int]] = {}
        # 默认创建VLAN 1
        self.create_vlan(1)
        for port in range(NUM_PORTS):
            self.add_port(1, port, untagged=True)
    
    def create_vlan(self, vid: int) -> bool:
        """创建VLAN"""
        if vid < 1 or vid >= VLAN_MAX:
            return False
        if vid not in self.member_ports:
            self.member_ports[vid] = set()
            self.untagged_ports[vid] = set()
        return True
    
    def delete_vlan(self, vid: int) -> bool:
        """删除VLAN"""
        if vid in self.member_ports:
            del self.member_ports[vid]
            del self.untagged_ports[vid]
            return True
        return False
    
    def add_port(self, vid: int, port: int, untagged: bool = False) -> bool:
        """添加端口到VLAN"""
        if vid not in self.member_ports:
            return False
        self.member_ports[vid].add(port)
        if untagged:
            self.untagged_ports[vid].add(port)
        return True
    
    def remove_port(self, vid: int, port: int) -> bool:
        """从VLAN移除端口"""
        if vid in self.member_ports:
            self.member_ports[vid].discard(port)
            self.untagged_ports[vid].discard(port)
            return True
        return False
    
    def get_member_ports(self, vid: int) -> Set[int]:
        """获取VLAN成员端口"""
        return self.member_ports.get(vid, set())
    
    def is_untagged(self, vid: int, port: int) -> bool:
        """检查端口是否为untagged"""
        return port in self.untagged_ports.get(vid, set())


# ============================================================================
# ACL引擎
# ============================================================================

class AclEngine:
    """ACL引擎 (TCAM)"""
    
    def __init__(self):
        self.rules: List[AclRule] = [AclRule() for _ in range(ACL_TABLE_SIZE)]
        self.rule_count = 0
    
    def add_rule(self, rule: AclRule) -> int:
        """添加ACL规则, 返回规则索引"""
        for i in range(ACL_TABLE_SIZE):
            if not self.rules[i].valid:
                self.rules[i] = rule
                self.rules[i].valid = True
                self.rule_count += 1
                return i
        return -1
    
    def delete_rule(self, index: int) -> bool:
        """删除ACL规则"""
        if 0 <= index < ACL_TABLE_SIZE and self.rules[index].valid:
            self.rules[index].valid = False
            self.rule_count -= 1
            return True
        return False
    
    def match(self, src_port: int, dmac: bytes, smac: bytes, 
              vid: int, ethertype: int) -> AclAction:
        """
        匹配ACL规则
        按优先级顺序匹配，返回第一个匹配的动作
        """
        best_match: Optional[AclRule] = None
        best_priority = -1
        
        for rule in self.rules:
            if not rule.valid:
                continue
            
            # 检查各字段匹配
            if rule.src_port_mask != 0:
                if (src_port & rule.src_port_mask) != (rule.src_port & rule.src_port_mask):
                    continue
            
            if not self._match_mac(dmac, rule.dmac, rule.dmac_mask):
                continue
            
            if not self._match_mac(smac, rule.smac, rule.smac_mask):
                continue
            
            if (vid & rule.vid_mask) != (rule.vid & rule.vid_mask):
                continue
            
            if (ethertype & rule.ethertype_mask) != (rule.ethertype & rule.ethertype_mask):
                continue
            
            # 匹配成功
            if rule.priority > best_priority:
                best_match = rule
                best_priority = rule.priority
        
        return best_match.action if best_match else AclAction.PERMIT
    
    def _match_mac(self, mac: bytes, rule_mac: bytes, mask: bytes) -> bool:
        """MAC地址掩码匹配"""
        for i in range(6):
            if (mac[i] & mask[i]) != (rule_mac[i] & mask[i]):
                return False
        return True


# ============================================================================
# Ingress Pipeline
# ============================================================================

class IngressPipeline:
    """
    入向流水线
    - 报文解析
    - ACL/QoS处理
    - MAC学习触发
    """
    
    def __init__(self, mac_table: MacTable, vlan_table: VlanTable, 
                 acl_engine: AclEngine, packet_buffer: PacketBuffer):
        self.mac_table = mac_table
        self.vlan_table = vlan_table
        self.acl_engine = acl_engine
        self.packet_buffer = packet_buffer
        self.port_config: List[PortConfig] = [PortConfig() for _ in range(NUM_PORTS)]
        # 统计
        self.rx_packets = 0
        self.rx_bytes = 0
        self.dropped_packets = 0
    
    def process(self, packet: Packet, src_port: int) -> Optional[PacketDescriptor]:
        """
        处理入向报文
        Returns:
            PacketDescriptor 或 None (丢弃)
        """
        # 检查端口状态
        port_cfg = self.port_config[src_port]
        if not port_cfg.enabled or port_cfg.state == PortState.DISABLED:
            self.dropped_packets += 1
            return None
        
        # 更新统计
        self.rx_packets += 1
        self.rx_bytes += packet.length
        port_cfg.rx_packets += 1
        port_cfg.rx_bytes += packet.length
        
        # Stage 1: 报文解析
        dmac = packet.dmac
        smac = packet.smac
        vid = packet.vid if packet.vid > 0 else port_cfg.default_vid
        pcp = packet.pcp if packet.vid > 0 else port_cfg.default_pcp
        ethertype = packet.ethertype
        
        # Stage 2: ACL检查
        acl_action = self.acl_engine.match(src_port, dmac, smac, vid, ethertype)
        if acl_action == AclAction.DENY:
            self.dropped_packets += 1
            port_cfg.rx_drops += 1
            return None
        
        # Stage 3: MAC学习 (仅在Learning或Forwarding状态)
        if port_cfg.state in (PortState.LEARNING, PortState.FORWARDING):
            # 检查SMAC是否为组播地址
            if not (smac[0] & 0x01):  # 非组播
                self.mac_table.learn(smac, vid, src_port)
        
        # Stage 4: 存储报文到缓冲区
        desc_id = self.packet_buffer.store_packet(packet, src_port)
        if desc_id is None:
            self.dropped_packets += 1
            port_cfg.rx_drops += 1
            return None
        
        # 填充描述符信息
        desc = self.packet_buffer.get_descriptor(desc_id)
        desc.src_port = src_port
        desc.queue_id = pcp  # 使用PCP作为队列ID
        
        # 确定VLAN动作
        if packet.vid == 0 and vid > 0:
            # 无tag进来，可能需要push
            desc.vlan_action = VlanAction.NONE  # 暂不push
        
        return desc


# ============================================================================
# Egress调度器
# ============================================================================

class EgressScheduler:
    """
    出向调度器
    - 384个队列 (48端口 × 8优先级)
    - SP + WRR两级调度
    """
    
    def __init__(self, packet_buffer: PacketBuffer):
        self.packet_buffer = packet_buffer
        # 队列描述符
        self.queues: List[List[QueueDescriptor]] = [
            [QueueDescriptor() for _ in range(NUM_QUEUES_PER_PORT)]
            for _ in range(NUM_PORTS)
        ]
        # 队列中的报文描述符ID链表
        self.queue_packets: List[List[deque]] = [
            [deque() for _ in range(NUM_QUEUES_PER_PORT)]
            for _ in range(NUM_PORTS)
        ]
        # WRR权重 (Q5~Q0)
        self.wrr_weights = [8, 4, 2, 2, 1, 1]
        self.wrr_counters: List[List[int]] = [
            [0] * 6 for _ in range(NUM_PORTS)
        ]
        # WRED门限
        self.wred_min_th = 100  # Cells
        self.wred_max_th = 500  # Cells
        self.wred_max_prob = 0.1
        # 统计
        self.enqueue_count = 0
        self.dequeue_count = 0
        self.drop_count = 0
    
    def enqueue(self, desc_id: int, dst_port: int, queue_id: int) -> bool:
        """
        报文入队
        """
        if dst_port < 0 or dst_port >= NUM_PORTS:
            return False
        if queue_id < 0 or queue_id >= NUM_QUEUES_PER_PORT:
            queue_id = 0
        
        q_desc = self.queues[dst_port][queue_id]
        
        # WRED检查
        if q_desc.length >= self.wred_max_th:
            # 尾部丢弃
            q_desc.drop_count += 1
            self.drop_count += 1
            return False
        elif q_desc.length >= self.wred_min_th:
            # 随机早期丢弃
            import random
            drop_prob = (q_desc.length - self.wred_min_th) / \
                       (self.wred_max_th - self.wred_min_th) * self.wred_max_prob
            if random.random() < drop_prob:
                q_desc.drop_count += 1
                self.drop_count += 1
                return False
        
        # 入队
        self.queue_packets[dst_port][queue_id].append(desc_id)
        
        # 更新描述符
        desc = self.packet_buffer.get_descriptor(desc_id)
        q_desc.length += desc.cell_count
        q_desc.enqueue_count += 1
        
        if q_desc.state == QueueState.EMPTY:
            q_desc.state = QueueState.NORMAL
        
        self.enqueue_count += 1
        return True
    
    def dequeue(self, port: int) -> Optional[int]:
        """
        从指定端口调度一个报文
        Returns:
            描述符ID 或 None
        """
        if port < 0 or port >= NUM_PORTS:
            return None
        
        # Level 1: 端口内优先级调度
        # Q7/Q6: Strict Priority
        for q in [7, 6]:
            if self.queue_packets[port][q]:
                return self._dequeue_from_queue(port, q)
        
        # Q5~Q0: WRR
        for _ in range(6):
            for q in range(5, -1, -1):
                if self.queue_packets[port][q]:
                    if self.wrr_counters[port][q] < self.wrr_weights[5-q]:
                        self.wrr_counters[port][q] += 1
                        return self._dequeue_from_queue(port, q)
            # 重置WRR计数器
            self.wrr_counters[port] = [0] * 6
        
        return None
    
    def _dequeue_from_queue(self, port: int, queue_id: int) -> Optional[int]:
        """从指定队列出队"""
        q_packets = self.queue_packets[port][queue_id]
        if not q_packets:
            return None
        
        desc_id = q_packets.popleft()
        q_desc = self.queues[port][queue_id]
        
        desc = self.packet_buffer.get_descriptor(desc_id)
        if desc:
            q_desc.length -= desc.cell_count
        
        q_desc.dequeue_count += 1
        
        if not q_packets:
            q_desc.state = QueueState.EMPTY
        
        self.dequeue_count += 1
        return desc_id
    
    def get_queue_depth(self, port: int, queue_id: int) -> int:
        """获取队列深度"""
        if 0 <= port < NUM_PORTS and 0 <= queue_id < NUM_QUEUES_PER_PORT:
            return self.queues[port][queue_id].length
        return 0


# ============================================================================
# Lookup Engine
# ============================================================================

class LookupEngine:
    """
    查表引擎
    - MAC查表
    - 转发决策
    """
    
    def __init__(self, mac_table: MacTable, vlan_table: VlanTable):
        self.mac_table = mac_table
        self.vlan_table = vlan_table
        # 组播组表
        self.mc_groups: Dict[int, Set[int]] = {}  # group_id -> port set
    
    def lookup(self, desc: PacketDescriptor, packet: Packet) -> Tuple[List[int], bool]:
        """
        执行查表
        Returns:
            (目的端口列表, 是否泛洪)
        """
        dmac = packet.dmac
        vid = packet.vid if packet.vid > 0 else 1
        
        # 检查是否为广播
        if dmac == b'\xff\xff\xff\xff\xff\xff':
            # 广播: 泛洪到VLAN内所有端口 (排除源端口)
            ports = self.vlan_table.get_member_ports(vid)
            ports = ports - {desc.src_port}
            return list(ports), True
        
        # 检查是否为组播
        if dmac[0] & 0x01:
            # 组播: 查组播组表或泛洪
            # 简化处理: 泛洪到VLAN
            ports = self.vlan_table.get_member_ports(vid)
            ports = ports - {desc.src_port}
            return list(ports), True
        
        # 单播查表
        dst_port = self.mac_table.lookup(dmac, vid)
        
        if dst_port is not None:
            # 命中
            if dst_port == desc.src_port:
                # 源端口过滤
                return [], False
            return [dst_port], False
        else:
            # 未命中: 泛洪
            ports = self.vlan_table.get_member_ports(vid)
            ports = ports - {desc.src_port}
            return list(ports), True
    
    def add_mc_group(self, group_id: int, ports: Set[int]):
        """添加组播组"""
        self.mc_groups[group_id] = ports
    
    def delete_mc_group(self, group_id: int):
        """删除组播组"""
        if group_id in self.mc_groups:
            del self.mc_groups[group_id]


# ============================================================================
# 交换机核心
# ============================================================================

class SwitchCore:
    """
    1.2Tbps交换机核心
    整合所有模块
    """
    
    def __init__(self):
        # 初始化各模块
        self.cell_allocator = CellAllocator()
        self.packet_buffer = PacketBuffer(self.cell_allocator)
        self.mac_table = MacTable()
        self.vlan_table = VlanTable()
        self.acl_engine = AclEngine()
        
        self.ingress = IngressPipeline(
            self.mac_table, self.vlan_table, 
            self.acl_engine, self.packet_buffer
        )
        self.lookup = LookupEngine(self.mac_table, self.vlan_table)
        self.egress = EgressScheduler(self.packet_buffer)
        
        # 端口配置
        self.port_config = self.ingress.port_config
        
        # 统计
        self.forwarded_packets = 0
        self.forwarded_bytes = 0
    
    def receive_packet(self, packet: Packet, src_port: int) -> bool:
        """
        接收并处理报文
        """
        # Ingress处理
        desc = self.ingress.process(packet, src_port)
        if desc is None:
            return False
        
        desc_id = self.packet_buffer.descriptors.index(desc)
        
        # 查表
        dst_ports, is_flood = self.lookup.lookup(desc, packet)
        
        if not dst_ports:
            # 无目的端口，丢弃
            self.packet_buffer.release_packet(desc_id)
            return False
        
        # 入队到目的端口
        if is_flood and len(dst_ports) > 1:
            # 组播/广播: 增加引用计数
            cell_id = desc.head_ptr
            while cell_id is not None:
                self.cell_allocator.increment_ref(cell_id, len(dst_ports) - 1)
                meta = self.cell_allocator.cell_meta[cell_id]
                cell_id = meta.next_ptr
        
        for dst_port in dst_ports:
            # 确定VLAN动作
            vid = packet.vid if packet.vid > 0 else self.port_config[src_port].default_vid
            if self.vlan_table.is_untagged(vid, dst_port) and packet.vid > 0:
                desc.vlan_action = VlanAction.POP
            elif not self.vlan_table.is_untagged(vid, dst_port) and packet.vid == 0:
                desc.vlan_action = VlanAction.PUSH
                desc.new_vid = vid
            
            self.egress.enqueue(desc_id, dst_port, desc.queue_id)
        
        self.forwarded_packets += 1
        self.forwarded_bytes += packet.length
        
        return True
    
    def transmit_packet(self, port: int) -> Optional[Tuple[bytes, int]]:
        """
        从指定端口发送报文
        Returns:
            (报文数据, 描述符ID) 或 None
        """
        # 调度
        desc_id = self.egress.dequeue(port)
        if desc_id is None:
            return None
        
        # 读取报文
        pkt_data = self.packet_buffer.retrieve_packet(desc_id)
        if pkt_data is None:
            return None
        
        # 更新统计
        self.port_config[port].tx_packets += 1
        self.port_config[port].tx_bytes += len(pkt_data)
        
        # 释放资源
        self.packet_buffer.release_packet(desc_id)
        
        return pkt_data, desc_id
    
    def get_statistics(self) -> Dict:
        """获取统计信息"""
        return {
            'forwarded_packets': self.forwarded_packets,
            'forwarded_bytes': self.forwarded_bytes,
            'free_cells': self.cell_allocator.get_free_count(),
            'mac_entries': self.mac_table.get_entry_count(),
            'mac_hit_rate': self.mac_table.hit_count / max(1, self.mac_table.lookup_count),
            'ingress_rx_packets': self.ingress.rx_packets,
            'ingress_dropped': self.ingress.dropped_packets,
            'egress_enqueued': self.egress.enqueue_count,
            'egress_dequeued': self.egress.dequeue_count,
            'egress_dropped': self.egress.drop_count,
        }
    
    def print_status(self):
        """打印状态"""
        stats = self.get_statistics()
        print("\n" + "=" * 60)
        print("1.2Tbps 48×25G L2 Switch Core Status")
        print("=" * 60)
        print(f"Forwarded Packets: {stats['forwarded_packets']}")
        print(f"Forwarded Bytes: {stats['forwarded_bytes']}")
        print(f"Free Cells: {stats['free_cells']} / {TOTAL_CELLS}")
        print(f"MAC Entries: {stats['mac_entries']} / {MAC_TABLE_SIZE}")
        print(f"MAC Hit Rate: {stats['mac_hit_rate']:.2%}")
        print(f"Ingress RX: {stats['ingress_rx_packets']}, Dropped: {stats['ingress_dropped']}")
        print(f"Egress Enqueued: {stats['egress_enqueued']}, Dequeued: {stats['egress_dequeued']}, Dropped: {stats['egress_dropped']}")
        print("=" * 60)


# ============================================================================
# 测试代码
# ============================================================================

def test_switch():
    """测试交换机功能"""
    print("Creating 1.2Tbps Switch Core...")
    switch = SwitchCore()
    
    # 创建测试报文
    print("\nTest 1: Unicast forwarding with MAC learning")
    
    # 报文1: Port 0 -> Port 1 (学习SMAC)
    pkt1 = Packet(
        dmac=b'\x00\x11\x22\x33\x44\x55',
        smac=b'\x00\xaa\xbb\xcc\xdd\xee',
        vid=1,
        pcp=3,
        ethertype=0x0800,
        payload=b'Hello World!' * 10
    )
    
    print(f"  Sending packet from port 0, SMAC={pkt1.smac.hex()}, DMAC={pkt1.dmac.hex()}")
    result = switch.receive_packet(pkt1, src_port=0)
    print(f"  Result: {'Accepted' if result else 'Dropped'} (flooded because DMAC unknown)")
    
    # 报文2: Port 1 -> Port 0 (学习SMAC, 使用已学习的DMAC)
    pkt2 = Packet(
        dmac=b'\x00\xaa\xbb\xcc\xdd\xee',  # 之前学习过
        smac=b'\x00\x11\x22\x33\x44\x55',
        vid=1,
        pcp=5,
        ethertype=0x0800,
        payload=b'Response!' * 10
    )
    
    print(f"\n  Sending packet from port 1, SMAC={pkt2.smac.hex()}, DMAC={pkt2.dmac.hex()}")
    result = switch.receive_packet(pkt2, src_port=1)
    print(f"  Result: {'Accepted' if result else 'Dropped'} (unicast to port 0)")
    
    # 报文3: 广播
    print("\nTest 2: Broadcast forwarding")
    pkt3 = Packet(
        dmac=b'\xff\xff\xff\xff\xff\xff',
        smac=b'\x00\x12\x34\x56\x78\x9a',
        vid=1,
        pcp=0,
        ethertype=0x0806,  # ARP
        payload=b'ARP Request' * 5
    )
    
    print(f"  Sending broadcast from port 2")
    result = switch.receive_packet(pkt3, src_port=2)
    print(f"  Result: {'Accepted' if result else 'Dropped'} (flooded to all VLAN 1 ports)")
    
    # 测试发送
    print("\nTest 3: Transmit packets from egress queues")
    for port in range(3):
        tx_result = switch.transmit_packet(port)
        if tx_result:
            pkt_data, desc_id = tx_result
            print(f"  Port {port}: Transmitted {len(pkt_data)} bytes")
        else:
            print(f"  Port {port}: No packet to transmit")
    
    # 打印状态
    switch.print_status()
    
    # 测试MAC表
    print("\nTest 4: MAC table lookup")
    port = switch.mac_table.lookup(b'\x00\xaa\xbb\xcc\xdd\xee', 1)
    print(f"  MAC 00:aa:bb:cc:dd:ee VLAN 1 -> Port {port}")
    
    port = switch.mac_table.lookup(b'\x00\x11\x22\x33\x44\x55', 1)
    print(f"  MAC 00:11:22:33:44:55 VLAN 1 -> Port {port}")
    
    # 性能测试
    print("\nTest 5: Performance test (10000 packets)")
    import time
    start = time.time()
    
    for i in range(10000):
        pkt = Packet(
            dmac=bytes([0x00, 0x11, 0x22, 0x33, (i >> 8) & 0xff, i & 0xff]),
            smac=bytes([0x00, 0xaa, 0xbb, 0xcc, (i >> 8) & 0xff, i & 0xff]),
            vid=1,
            pcp=i % 8,
            ethertype=0x0800,
            payload=b'X' * 100
        )
        switch.receive_packet(pkt, src_port=i % NUM_PORTS)
    
    elapsed = time.time() - start
    pps = 10000 / elapsed
    print(f"  Processed 10000 packets in {elapsed:.3f}s ({pps:.0f} pps)")
    
    switch.print_status()
    
    print("\nAll tests completed!")


if __name__ == '__main__':
    test_switch()
