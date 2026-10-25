#!/usr/bin/env python3
"""Independent GDB-RSP peer over pipes. No debugger/device/process attachment.
Only synthetic addresses, challenge bytes and zero-filled byte arrays are used.
"""
import base64
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CHALLENGE = bytes(range(1,33))
PAGE = 16384
# Base: size, as tools/probe_debug_arena.swift asks. 131 pages: the second
# preparation batch spans both arenas.
REGIONS = {0x200000:130*PAGE,0x1000000:PAGE}
LAST = 0x1000000

def frame(text,checksum=True):
    b = text.encode('ascii')
    encoded = b''.join(bytes([125,v^32]) if v in b'$#}*' else bytes([v]) for v in b)
    return b'$'+encoded+b'#'+(f'{sum(encoded)%256:02x}' if checksum else '00').encode()

def command(wire):
    assert wire[0:1] == b'$' and wire[-3:-2] == b'#'
    b = wire[1:-3]; assert sum(b)%256 == int(wire[-2:],16)
    result = bytearray(); escaped = False
    for v in b:
        if escaped: result.append(v^32); escaped=False
        elif v == 125: escaped=True
        else: result.append(v)
    assert not escaped
    return result.decode('ascii')

def commands_in(wire):
    result=[]
    while wire:
        end=wire.index(b'#')+3; result.append(command(wire[:end])); wire=wire[end:]
    return result

class Driver:
    def __enter__(self):
        self.p = subprocess.Popen([str(ROOT/'build/probe_debug_arena')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        self.now = 0
        self.step = .001
        return self
    def __exit__(self,*args):
        self.p.stdin.close(); self.p.wait(timeout=3); assert self.p.returncode == 0
    def call(self,**value):
        value['now'] = self.now
        self.p.stdin.write(json.dumps(value)+'\n'); self.p.stdin.flush()
        result = json.loads(self.p.stdout.readline()); assert 'error' not in result,result
        return result
    def send(self,wire):
        self.now += self.step
        return self.call(data=base64.b64encode(wire).decode())

def emitted(result):
    commands=[]; terminal=[]; controls=[]
    for event in result['events']:
        if 'send' in event:
            b = base64.b64decode(event['send'])
            if b in (b'+',b'-'): controls.append(b)
            else: commands.extend(commands_in(b))
        else: terminal.append(event)
    return commands,terminal,controls

def exchange(mode='success',packet_size='1000',fragment=False,time_step=.001):
    read_next={base:0 for base in REGIONS}; writes=[]; readback=[]; batches=[]
    state={'noack':False,'process_queries':0,'challenge_reads':0,'detach':False}
    def region(address): return next(base for base,size in REGIONS.items() if base<=address<base+size)
    def respond(text):
        if text == 'qSupported': return 'PacketSize='+packet_size+';qXfer:features:read+'
        if text == 'QStartNoAckMode': return '' if mode == 'unsupported_no_ack' else 'OK'
        if text == 'QSetDetachOnError:1': return '' if mode == 'unsupported_detach_policy' else 'OK'
        if text.startswith('vAttach;'):
            assert text == 'vAttach;4d2'
            return 'E01' if mode == 'attach_error' else 'T13thread:7;'
        if text == 'qProcessInfo':
            state['process_queries'] += 1
            pid = '4d3' if mode == 'wrong_pid' or (mode=='final_pid' and state['process_queries']==2) else '4d2'
            uid = '0' if mode == 'wrong_uid' else '1f5'
            cpu = '1000007' if mode == 'wrong_arch' else '100000c'
            response = f'pid:{pid};effective-uid:{uid};cputype:{cpu};ptrsize:8;endian:little;'
            return response+'pid:4d2;' if mode == 'duplicate_pid' else response
        if text.startswith('qMemoryRegionInfo:'):
            address = int(text.split(':')[1],16); assert address in REGIONS
            permission = 'rwx' if mode=='unsafe_last' and address==LAST else 'rx'
            response = f'start:{address:x};size:{REGIONS[address]:x};permissions:{permission};'
            return response+'name:2f6170702f62696e617279;' if mode=='file_backed' else response
        if text.startswith('m'):
            address,count = (int(v,16) for v in text[1:].split(','))
            if address == 0x100000:
                assert count==32
                state['challenge_reads']+=1
                if mode=='wrong_challenge' or (mode=='final_challenge' and state['challenge_reads']==2): return 'ff'*32
                return CHALLENGE.hex()
            base = region(address)
            if writes:
                # Read-back: the byte just written.
                assert count==1 and address==writes[-1]
                readback.append(address)
                return '01' if mode=='verify_corrupt' and len(readback)==3 else '00'
            # Preflight: each arena in order, every byte once.
            assert count > 0 and address==base+read_next[base] and address+count<=base+REGIONS[base]
            read_next[base]+=count
            response = '00'*count
            if mode=='nonzero_last' and base==LAST: response='01'+response[2:]
            if mode=='short_read': response=response[:-2]
            return response
        if text.startswith('M'):
            header,data = text[1:].split(':'); address,count=(int(v,16) for v in header.split(','))
            assert all(read_next[b]==REGIONS[b] for b in REGIONS),'write before full preflight'
            assert count==1 and data=='00' and (address-region(address))%PAGE==0 and address not in writes
            assert len(text)<=min(int(packet_size,16),32768)
            writes.append(address)
            return 'E0e' if mode=='write_error' and len(writes)==2 else 'OK'
        if text=='D':
            state['detach']=True; return 'E01' if mode=='detach_error' else 'OK'
        raise AssertionError(text)
    with Driver() as driver:
        driver.step=time_step
        commands,terminal,_ = emitted(driver.call(begin=True))
        while commands:
            # Acknowledged commands go one at a time; detaching goes alone.
            assert len(commands)==1 or (state['noack'] and 'D' not in commands),(mode,commands)
            if any(text[0] in 'mM' for text in commands) and len(commands)>1: batches.append(len(commands))
            acked=not state['noack']
            responses=[respond(text) for text in commands]
            if commands==['QStartNoAckMode'] and responses==['OK']: state['noack']=True
            # Like Apple's debugserver: #00 once acknowledgements are off.
            wire=b''.join((b'+' if acked else b'')+frame(r,checksum=acked or mode=='no_ack_checksums') for r in responses)
            if mode=='detach_trailing' and commands==['D']: wire+=b'junk'
            if mode=='ack_without_ack_mode' and commands[0].startswith('vAttach'): wire=b'+'+wire
            # As a transport delivers a batch's replies: in pieces.
            pieces=[wire[:1],wire[1:2],wire[2:19],wire[19:]] if fragment else [wire]
            results=[]
            for piece in pieces:
                for at in range(0,len(piece),30000): results.extend(driver.send(piece[at:at+30000])['events'])
            result={'events':results}
            last=commands
            commands,finished,controls=emitted(result)
            expected=[b'+']*len(responses) if acked and not (mode=='detach_trailing' and last==['D']) else []
            assert controls==expected,(mode,last,controls)
            terminal+=finished
        assert len(terminal)==1,(mode,terminal)
        result=terminal[0]
        if mode in ('success','no_ack_checksums'):
            assert result.get('success') is True and result['pid']==1234 and result['regions']==2
            pages=[base+n*PAGE for base,size in REGIONS.items() for n in range(size//PAGE)]
            assert state['detach'] and writes==pages and readback==pages
            assert batches[-2:]==[256,6] and all(n<=4 for n in batches[:-2]),batches
        else:
            assert 'failure' in result and not result.get('success')
            if mode in ('wrong_pid','wrong_uid','wrong_arch','duplicate_pid','wrong_challenge','unsafe_last','file_backed','nonzero_last','short_read'):
                assert not writes and state['detach'] and result['detached'] is True
            if mode in ('write_error','verify_corrupt','final_pid','final_challenge'):
                assert writes and state['detach'] and result['detached'] is True
            if mode in ('unsupported_no_ack','unsupported_detach_policy','attach_error','ack_without_ack_mode'):
                assert not state['process_queries'] and result['detached'] is False
            if mode in ('detach_error','detach_trailing'):
                assert result['detached'] is False
            if mode=='detach_trailing': assert result['failure']=='protocolFailure' and state['detach']
        if time_step==.25: assert 900 < driver.now < 1800,driver.now
        if mode=='total_deadline': assert driver.now>=1800 and result['failure']=='timedOut'
        assert driver.call(tick=True)['events']==[]
        return result

def main():
    for mode in ['success','wrong_pid','wrong_uid','wrong_arch','duplicate_pid','wrong_challenge','unsafe_last','file_backed',
                 'nonzero_last','short_read','write_error','verify_corrupt','final_pid','final_challenge','detach_error','detach_trailing',
                 'attach_error','unsupported_no_ack','unsupported_detach_policy','ack_without_ack_mode']:
        exchange(mode,fragment=mode=='success')
    exchange(packet_size='8000'); exchange(packet_size='100')
    # Simulated time: sustained valid work beyond the former deadline succeeds,
    # but the new absolute bound still terminates progress. No wall-clock wait.
    exchange(packet_size='100',time_step=.25)
    exchange(mode='total_deadline',packet_size='100',time_step=.5)
    assert exchange('no_ack_checksums').get('success') is True
    for mode in ('checksum','nack','deadline','disconnect','cancel','coalesced','response_without_ack'):
        with Driver() as d:
            first=d.call(begin=True)
            if mode=='checksum':
                bad=bytearray(frame('PacketSize=1000'));bad[-1]=ord('0') if bad[-1]!=ord('0') else ord('1')
                result=d.send(b'+'+bad);assert emitted(result)==([],[],[b'-'])
                result=d.send(frame('PacketSize=1000'));assert emitted(result)[0]==['QStartNoAckMode']
            elif mode=='nack':
                assert d.send(b'-')['events']==first['events']
                assert d.send(b'-')['events']==first['events']
                assert emitted(d.send(b'-'))[1][0]['failure']=='protocolFailure'
            elif mode=='deadline':
                d.now=10;assert emitted(d.call(tick=True))[1][0]=={'failure':'timedOut','detached':False}
            elif mode in ('disconnect','cancel'):
                assert emitted(d.call(**{mode:True}))[1][0]['detached'] is False
            elif mode=='coalesced':
                result=d.send(b'+'+frame('PacketSize=1000')+b'+'+frame('OK'))
                c,t,_=emitted(result);assert not c and t[0]['failure']=='protocolFailure'
            else:
                assert emitted(d.send(frame('PacketSize=1000')))[1][0]['failure']=='protocolFailure'
    # Without acknowledgements a damaged reply is a failure, not a retry.
    with Driver() as d:
        d.call(begin=True);d.send(b'+'+frame('PacketSize=1000'))
        assert emitted(d.send(b'+'+frame('OK')))[0]==['QSetDetachOnError:1']
        bad=bytearray(frame('OK'));bad[-1]=ord('0') if bad[-1]!=ord('0') else ord('1')
        c,t,controls=emitted(d.send(bytes(bad)));assert not c and not controls and t[0]['failure']=='protocolFailure'
    # Unsupported tiny/overflow PacketSize cannot produce an attach command.
    for value in ('ff','10000000000000000','xyz'):
        with Driver() as d:
            d.call(begin=True);c,t,_=emitted(d.send(b'+'+frame('PacketSize='+value)))
            assert not c and len(t)==1 and t[0]['detached'] is False
    # Trailing unsolicited bytes must also discard a queued next command.
    with Driver() as d:
        d.call(begin=True)
        r=d.send(b'+'+frame('PacketSize=1000')+b'junk')
        assert not emitted(r)[0] and emitted(r)[1][0]['failure']=='protocolFailure'
    text='PASS: independent RSP peer validated exact PID/UID/architecture/challenge, all-arenas preflight, one zero byte per page written and read back in batches, no-ack mode, detach confirmation after draining a failed batch, small/large packets, fragmentation, checksums, NACK limits, errors and timeouts\n'
    (ROOT/'build/debug-arena-peer-tests.log').write_text(text);print(text,end='')

if __name__=='__main__':main()
