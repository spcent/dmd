/**
 Written by Stefan Koch
 In April 2017
*/

module ddmd.ctfe.bc_x86_backend;
import ddmd.ctfe.bc_common;

struct BCFunction
{
    uint id;
    void* funcDecl;
    // some local state

}

struct FunctionState
{
    uint begin;

    StackAddr sp = StackAddr(4);

    ubyte parameterCount;
    ushort temporaryCount;
}
/*
        uint cndJumpCount;
        uint jmpCount;
        ubyte parameterCount;
        ushort temporaryCount;
        uint labelCount;
        bool sameLabel;
        StackAddr sp = StackAddr(4);

*/

    enum Reg : ubyte
    {
        EAX, /// Extended Accumulator 0
        ECX, /// Extended Counter 1
        EDX, /// Extended Data 2
        EBX, /// Extended Base 3
        ESP, /// Extended Stack Pointer 4
        EBP, /// Extended Base Pointer 5
        ESI, /// Extended Source Index 6
        EDI /// Extended Destination Index 7
    }

struct X86_BCGen
{

    bool insideFunction;
    ubyte[ushort.max / 16] code;
    uint ip = 4;
    uint sp = 4;
    BCAddr[32] StackSizeFixup;
    uint StackSizeFixupCount;

    FunctionState[ubyte.max * 8] functions;
    // uint currentFunction;
    uint functionCount;

    FunctionState* currentFunctionState;
    void Initialize()
    {
        assert(!insideFunction);

        currentFunctionState = &functions[0];
        foreach (uint fs; 0 .. functionCount)
        {
            functions[fs] = FunctionState.init;
        }
        functionCount = 0;

        ip = 0;
        // set the array to halts
        foreach (_; 0 .. code.length)
        {
            Hlt();
        }
        ip = 4;
        sp = 4;

    }

    void Finalize()
    {
    }

    void beginFunction(uint id = 0)
    {
        assert(!insideFunction);
        insideFunction = true;
        if (functionCount != id)
        {
            assert(0, "functionCount is not id");
        }
        // write preamble
        // push ebp
        // mov ebp, esp
        // sub esp, numberOfLocals*4
        Push(Reg.EBP);
        Push(Reg.ESP);
        Mov(Reg.EBP, Reg.ESP);
        SubImm32(Reg.ESP, imm32(4));
        AddImm32(Reg.ESP, imm32(uint.max));
        StackSizeFixup[StackSizeFixupCount++] = ip - 4;
    }

    BCFunction endFunction()
    {
        assert(insideFunction);
        insideFunction = false;
        currentFunctionState = &functions[++functionCount];
        return BCFunction.init;
    }

    // private specific helpers

    void Ud2()
    {
        code[ip] = 0x0F;
        code[ip + 1] = 0x0B;
        ip += 2;
        //       *(cast(ushort*)code[ip]) = 0x0F0B;
    }

    void Hlt()
    {
        code[ip++] = 0xF4;
    }

    void Not(Reg r)
    {
        code[ip++] = 0xF7;
        code[ip++] = 0xD0 | r;
    }

    void Mov(Reg dst, Reg src)
    {
        code[ip++] = 0x89;
        code[ip++] = cast(ubyte)(0b11 << 6 | src << 3 | dst);
    }

    void MovImm32(Reg r, BCValue v)
    {
        assert(v.vType == BCValueType.Immediate, "for now only immediates are supported");
        if (v.vType == BCValueType.Immediate)
        {
            code[ip++] = 0xB8 | r;
            WriteLE32(v.imm32);
        }
    }

    void AddImm32(Reg r, BCValue v)
    {
        assert(v.vType == BCValueType.Immediate, "for now only immediates are supported");
        if (v.vType == BCValueType.Immediate)
        {
            if (r == Reg.EAX)
            {
                code[ip++] = 0x05 | r;
                WriteLE32(v.imm32);
            }
            else
            {
                code[ip++] = 0x81;
                code[ip++] = 0xC0 | r;
                WriteLE32(v.imm32);
            }
        }
    }

    void SubImm32(Reg r, BCValue v)
    {
        assert(v.vType == BCValueType.Immediate, "for now only immediates are supported");
        if (v.vType == BCValueType.Immediate)
        {
            if (r == Reg.EAX)
            {
                code[ip++] = 0x2D;
                WriteLE32(v.imm32);
            }
            else
            {
                code[ip++] = 0x81;
                code[ip++] = 0xE8 | r;
                WriteLE32(v.imm32);
            }
        }
    }

    void OrImm32(Reg r, BCValue v)
    {
        assert(v.vType == BCValueType.Immediate, "for now only immediates are supported");
        if (v.vType == BCValueType.Immediate)
        {
            code[ip++] = 0x0D | r;
            WriteLE32(v.imm32);
        }
    }

    void Push(Reg r)
    {
        code[ip++] = 0x50 | r;
    }

    void Retn(ushort stackSize)
    {
        if (stackSize == 0)
        {
            code[ip++] = 0xC3;
        }
        else
        {
            code[ip++] = 0xC2;
            code[ip++] = stackSize & 0xFF;
            code[ip++] = (stackSize >> 8) & 0xFF;
        }
    }

    void WriteLE32(uint imm32) pure
    {
        code[ip] = imm32 & 255;
        code[ip + 1] = (imm32 >> 8) & 255;
        code[ip + 2] = (imm32 >> 16) & 255;
        code[ip + 3] = (imm32 >> 24) & 255;
        ip += 4;
    }

    /* Preamble
   0:	55                   	push   ebp
   1:	89 e5                	mov    ebp,esp
   3:	83 ec 14             	sub    esp,0x14
*/

    BCValue genTemporary(BCType bct)
    {
        auto size = basicTypeSize(bct);
        sp += 4;
         
    }
    BCValue genParameter(BCType bct);
    BCAddr beginJmp()
    {
        code[ip++] = 0xE9;
        scope(exit) ip += 4;
        return BCAddr(ip);
    }
    void endJmp(BCAddr atIp, BCLabel target)
    {
        int offset = target.addr - (atIp + 4);
        const oldIp = ip;
        ip = atIp;
        WriteLE32(offset);
        ip = oldIp;
    }
    void incSp()
    {
        sp += 4;
    }
    StackAddr currSp();
    BCLabel genLabel()
    {
        return BCLabel(BCAddr(ip));
    }
    CndJmpBegin beginCndJmp(BCValue cond = BCValue.init, bool ifTrue = false);
    void endCndJmp(CndJmpBegin jmp, BCLabel target);
    void genJump(BCLabel target);
    void emitFlg(BCValue lhs);
    void Alloc(BCValue heapPtr, BCValue size);
    void Assert(BCValue value, BCValue err);
    void Not(BCValue result, BCValue val);
    void Set(BCValue lhs, BCValue rhs);
    void Lt3(BCValue result, BCValue lhs, BCValue rhs);
    void Le3(BCValue result, BCValue lhs, BCValue rhs);
    void Gt3(BCValue result, BCValue lhs, BCValue rhs);
    void Eq3(BCValue result, BCValue lhs, BCValue rhs);
    void Neq3(BCValue result, BCValue lhs, BCValue rhs);
    void Add3(BCValue result, BCValue lhs, BCValue rhs)
    {
        //        assert(isStackValueOrParameter(result), "Add result is no stack value");
        //        assert(result.type.type == BCTypeEnum.i32);
        assert(lhs.type.type == BCTypeEnum.i32);
        assert(rhs.type.type == BCTypeEnum.i32);
        if (lhs.vType == BCValueType.Immediate)
        {
            MovImm32(Reg.EAX, lhs);
        }
        if (rhs.vType == BCValueType.Immediate)
        {
            AddImm32(Reg.EAX, rhs);
        }
    }

    void Sub3(BCValue result, BCValue lhs, BCValue rhs);
    void Mul3(BCValue result, BCValue lhs, BCValue rhs);
    void Div3(BCValue result, BCValue lhs, BCValue rhs);
    void And3(BCValue result, BCValue lhs, BCValue rhs);
    void Or3(BCValue result, BCValue lhs, BCValue rhs);
    void Xor3(BCValue result, BCValue lhs, BCValue rhs);
    void Lsh3(BCValue result, BCValue lhs, BCValue rhs);
    void Rsh3(BCValue result, BCValue lhs, BCValue rhs);
    void Mod3(BCValue result, BCValue lhs, BCValue rhs);
    import ddmd.globals : Loc;

    void Call(BCValue result, BCValue fn, BCValue[] args, Loc l = Loc.init);
    void Load32(BCValue _to, BCValue from);
    void Store32(BCValue _to, BCValue value);
    void Ret(BCValue val)
    {
        if (val.vType == BCValueType.Immediate)
        {
            MovImm32(Reg.EAX, val);
            Retn(ushort.max);
            StackSizeFixup[StackSizeFixupCount++] = ip - 2;
        }
    }

    ubyte[] dump()
    {
        return code[4 .. ip];
    }
}

enum LegacyPrefix : ubyte
{
    OperandSizeOverride = 0x66,
    AddressSizeOverride = 0x67,
    SegmentOverrideCS = 0x2E,
    SegmentOverrideDS = 0x3E,
    SegmentOverrideES = 0x26,
    SegmentOverrideFS = 0x64,
    SegmentOverrideGS = 0x65,
    SegmentOverrideSS = 0x36,
    Lock = 0xF0,
    REPZ = 0xF3,
    REPNZ = 0xF2,
}

struct PrefixState
{
    uint _state;
    @property OperandSizeOverride()
    {
        return _state & ~1;
    }

    @property AddressSizeOverride()
    {
        return _state & ~2;
    }

    @property SegmentOverrideCS()
    {
        return _state & ~4;
    }

    @property SegmentOverrideDS()
    {
        return _state & ~8;
    }

    @property SegmentOverrideES()
    {
        return _state & ~16;
    }

    @property SegmentOverrideFS()
    {
        return _state & ~32;
    }

    @property SegmentOverrideGS()
    {
        return _state & ~64;
    }

    @property SegmentOverrideSS()
    {
        return _state & ~128;
    }

    @property Lock()
    {
        return _state & ~256;
    }

    @property REPZ()
    {
        return _state & ~512;
    }

    @property REPNZ()
    {
        return _state & ~1024;
    }

    @property OperandSizeOverride(bool v)
    {
        _state |= 1;
    }

    @property AddressSizeOverride(bool v)
    {
        _state |= 2;
    }

    @property SegmentOverrideCS(bool v)
    {
        _state |= 4;
    }

    @property SegmentOverrideDS(bool v)
    {
        _state |= 8;
    }

    @property SegmentOverrideES(bool v)
    {
        _state |= 16;
    }

    @property SegmentOverrideFS(bool v)
    {
        _state |= 32;
    }

    @property SegmentOverrideGS(bool v)
    {
        _state |= 64;
    }

    @property SegmentOverrideSS(bool v)
    {
        _state |= 128;
    }

    @property Lock(bool v)
    {
        _state |= 256;
    }

    @property REPZ(bool v)
    {
        _state |= 512;
    }

    @property REPNZ(bool v)
    {
        _state |= 1024;
    }

    void parse(ubyte[] code, uint* pos)
    {
        bool defaultHit;
        while (!defaultHit) switch (code[*pos])
        {
        default:
            defaultHit = true;
            break;
        case LegacyPrefix.OperandSizeOverride:
            OperandSizeOverride = true;
            ++(*pos);
            break;
        case LegacyPrefix.AddressSizeOverride:
            AddressSizeOverride = true;
            ++(*pos);
            break;
        case LegacyPrefix.SegmentOverrideCS:
            SegmentOverrideCS = true;
            ++(*pos);
            break;
        case LegacyPrefix.SegmentOverrideDS:
            SegmentOverrideDS = true;
            ++(*pos);
            break;
        case LegacyPrefix.SegmentOverrideES:
            SegmentOverrideES = true;
            ++(*pos);
            break;
        case LegacyPrefix.SegmentOverrideFS:
            SegmentOverrideFS = true;
            ++(*pos);
            break;
        case LegacyPrefix.SegmentOverrideGS:
            SegmentOverrideGS = true;
            ++(*pos);
            break;
        case LegacyPrefix.SegmentOverrideSS:
            SegmentOverrideSS = true;
            ++(*pos);
            break;
        case LegacyPrefix.Lock:
            Lock = true;
            ++(*pos);
            break;
        case LegacyPrefix.REPZ:
            REPZ = true;
            ++(*pos);
            break;
        case LegacyPrefix.REPNZ:
            REPNZ = true;
            ++(*pos);
            break;
        }
    }
    /** to regen
  pragma(msg, ()
  {
    string getters;
    string setters;
    string parseFunc = "void parse(ubyte[] code, uint* pos) {\n" ~
        "bool defaultHit;\n" ~
        "while(!defaultHit) switch(code[pos]) {\n" ~
        "\tdefault : defaultHit = true; break; \n";
    auto members = [__traits(allMembers, LegacyPrefix)];

    foreach(i,m;members)
    {
      import std.conv : to;
      auto shift = (1 << i).to!string;
      getters ~= "@property " ~ m ~ " () { \n"
          ~ "\treturn _state & ~" ~ shift ~ ";\n}\n";

      setters ~= "@property " ~ m ~ " (bool v) { \n" ~
          "\t_state |= " ~ shift ~ ";\n}\n";

      parseFunc ~= "\tcase LegacyPrefix." ~ m ~ " :\n" ~
           "\t\t" ~ m ~ " = true;\n" ~
           "\t\t++(*pos);\n" ~
           "\t\tbreak;\n";
    }
    parseFunc ~= "}}";
   return getters ~ setters ~ parseFunc;
  }());
*/
}

ulong fromBytes(ubyte[] arr, uint* pos, uint size)
{
    ulong result;
    auto _pos = *pos;
    foreach (i, ulong e; arr[_pos .. _pos + size])
    {
        result |= e << (i * 8L);
    }
    (*pos) = _pos + size;
    return result;
}

string dis(ubyte[] code)
{

    uint pos;
    import std.conv : to;
    string result;
    PrefixState ps;
    while (pos < code.length)
    {
        result ~= "\n";
        ps.parse(code, &pos);
        auto b = code[pos++];
        switch (b)
        {
        case 0x00:
            {
                result ~= "ADD ";
            }
            break;
        case 0x05:
            {
                result ~= "ADD EAX, #" ~ to!string(fromBytes(code, &pos, 4));
            }
            break;
        case 0xF4 :
            {
                result ~= "HLT";
            }
            break;
        case 0x81 :
            {
                Reg target;
                target = cast(Reg)(code[pos++] & ~0xC0);
                result ~= "ADD " ~ to!string(target)[4 .. $] ~", #" ~ to!string(fromBytes(code, &pos, 4));
            }
            break;
        default:
            result ~= "unkown opcode: " ~ asHex([b]);
        }
        ps._state = 0;
    }

    return result;

}

pragma(msg, dis([0xf4, 0x05, 0x00, 0xFF, 0x00, 0xFE, 0xf4]));

string asHex(ubyte[] arr)
{
    char[] result;

    result.length = (cast(uint)(arr.length) * 3);

    foreach (i, b; arr)
    {
        auto ln = b & 0xF;
        auto hn = (b & 0xF0) >> 4;

        result[i * 3 + 0] = cast(char)(hn > 9 ? ('A' - 10) + hn : '0' + hn);
        result[i * 3 + 1] = cast(char)(ln > 9 ? ('A' - 10) + ln : '0' + ln);

        result[i * 3 + 2] = ' ';
    }

    return cast(string) result[0 .. $ - 1];
}

pragma(msg, asHex({
X86_BCGen gen;
with(gen)
{
    Initialize();
    beginFunction();
    auto jmp = beginJmp();
    Add3(imm32(0), imm32(12), imm32(35));
    endJmp(jmp, genLabel());
    Add3(imm32(0), imm32(24), imm32(70));
    endFunction();
    Finalize();
    return code[0 .. ip];
}
}()
));
