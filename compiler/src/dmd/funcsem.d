/**
 * Does semantic analysis for functions.
 *
 * Specification: $(LINK2 https://dlang.org/spec/function.html, Functions)
 *
 * Copyright:   Copyright (C) 1999-2024 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 https://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/funcsem.d, _funcsem.d)
 * Documentation:  https://dlang.org/phobos/dmd_funcsem.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/funcsem.d
 */

module dmd.funcsem;

import core.stdc.stdio;

import dmd.aggregate;
import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.blockexit;
import dmd.gluelayer;
import dmd.dcast;
import dmd.dclass;
import dmd.declaration;
import dmd.delegatize;
import dmd.dinterpret;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.escape;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.importc;
import dmd.init;
import dmd.location;
import dmd.mtype;
import dmd.mustuse;
import dmd.objc;
import dmd.opover;
import dmd.pragmasem;
import dmd.root.aav;
import dmd.common.outbuffer;
import dmd.rootobject;
import dmd.root.filename;
import dmd.root.string;
import dmd.root.stringtable;
import dmd.semantic2;
import dmd.semantic3;
import dmd.statement_rewrite_walker;
import dmd.statement;
import dmd.statementsem;
import dmd.target;
import dmd.tokens;
import dmd.typesem;
import dmd.visitor;

/**********************************
 * Main semantic routine for functions.
 */
void funcDeclarationSemantic(Scope* sc, FuncDeclaration funcdecl)
{
    version (none)
    {
        printf("FuncDeclaration::semantic(sc = %p, this = %p, '%s', linkage = %d)\n", sc, funcdecl, funcdecl.toPrettyChars(), sc.linkage);
        if (funcdecl.isFuncLiteralDeclaration())
            printf("\tFuncLiteralDeclaration()\n");
        printf("sc.parent = %s, parent = %s\n", sc.parent.toChars(), funcdecl.parent ? funcdecl.parent.toChars() : "");
        printf("type: %p, %s\n", funcdecl.type, funcdecl.type.toChars());
    }

    if (funcdecl.semanticRun != PASS.initial && funcdecl.isFuncLiteralDeclaration())
    {
        /* Member functions that have return types that are
         * forward references can have semantic() run more than
         * once on them.
         * See test\interface2.d, test20
         */
        return;
    }

    if (funcdecl.semanticRun >= PASS.semanticdone)
        return;
    assert(funcdecl.semanticRun <= PASS.semantic);
    funcdecl.semanticRun = PASS.semantic;

    if (funcdecl._scope)
    {
        sc = funcdecl._scope;
        funcdecl._scope = null;
    }

    if (!sc || funcdecl.errors)
        return;

    funcdecl.cppnamespace = sc.namespace;
    funcdecl.parent = sc.parent;
    Dsymbol parent = funcdecl.toParent();

    funcdecl.foverrides.setDim(0); // reset in case semantic() is being retried for this function

    funcdecl.storage_class |= sc.stc & ~STC.ref_;
    AggregateDeclaration ad = funcdecl.isThis();
    // Don't nest structs b/c of generated methods which should not access the outer scopes.
    // https://issues.dlang.org/show_bug.cgi?id=16627
    if (ad && !funcdecl.isGenerated())
    {
        funcdecl.storage_class |= ad.storage_class & (STC.TYPECTOR | STC.synchronized_);
        ad.makeNested();
    }
    if (sc.func)
        funcdecl.storage_class |= sc.func.storage_class & STC.disable;
    // Remove prefix storage classes silently.
    if ((funcdecl.storage_class & STC.TYPECTOR) && !(ad || funcdecl.isNested()))
        funcdecl.storage_class &= ~STC.TYPECTOR;

    //printf("function storage_class = x%llx, sc.stc = x%llx, %x\n", storage_class, sc.stc, Declaration.isFinal());

    if (sc.flags & SCOPE.compile)
        funcdecl.skipCodegen = true;

    funcdecl._linkage = sc.linkage;
    if (sc.flags & SCOPE.Cfile && funcdecl.isFuncLiteralDeclaration())
        funcdecl._linkage = LINK.d; // so they are uniquely mangled

    if (auto fld = funcdecl.isFuncLiteralDeclaration())
    {
        if (fld.treq)
        {
            Type treq = fld.treq;
            assert(treq.nextOf().ty == Tfunction);
            if (treq.ty == Tdelegate)
                fld.tok = TOK.delegate_;
            else if (treq.isPtrToFunction())
                fld.tok = TOK.function_;
            else
                assert(0);
            funcdecl._linkage = treq.nextOf().toTypeFunction().linkage;
        }
    }

    // evaluate pragma(inline)
    if (auto pragmadecl = sc.inlining)
        funcdecl.inlining = evalPragmaInline(pragmadecl.loc, sc, pragmadecl.args);

    funcdecl.visibility = sc.visibility;
    funcdecl.userAttribDecl = sc.userAttribDecl;
    UserAttributeDeclaration.checkGNUABITag(funcdecl, funcdecl._linkage);
    checkMustUseReserved(funcdecl);

    if (!funcdecl.originalType)
        funcdecl.originalType = funcdecl.type.syntaxCopy();

    static TypeFunction getFunctionType(FuncDeclaration fd)
    {
        if (auto tf = fd.type.isTypeFunction())
            return tf;

        if (!fd.type.isTypeError())
        {
            .error(fd.loc, "%s `%s` `%s` must be a function instead of `%s`", fd.kind, fd.toPrettyChars, fd.toChars(), fd.type.toChars());
            fd.type = Type.terror;
        }
        fd.errors = true;
        return null;
    }

    if (sc.flags & SCOPE.Cfile)
    {
        /* C11 allows a function to be declared with a typedef, D does not.
         */
        if (auto ti = funcdecl.type.isTypeIdentifier())
        {
            auto tj = ti.typeSemantic(funcdecl.loc, sc);
            if (auto tjf = tj.isTypeFunction())
            {
                /* Copy the type instead of just pointing to it,
                 * as we don't merge function types
                 */
                auto tjf2 = new TypeFunction(tjf.parameterList, tjf.next, tjf.linkage);
                funcdecl.type = tjf2;
                funcdecl.originalType = tjf2;
            }
        }
    }

    if (!getFunctionType(funcdecl))
        return;

    if (!funcdecl.type.deco)
    {
        sc = sc.push();
        sc.stc |= funcdecl.storage_class & (STC.disable | STC.deprecated_); // forward to function type

        TypeFunction tf = funcdecl.type.toTypeFunction();
        if (sc.func)
        {
            /* If the nesting parent is pure without inference,
             * then this function defaults to pure too.
             *
             *  auto foo() pure {
             *    auto bar() {}     // become a weak purity function
             *    class C {         // nested class
             *      auto baz() {}   // become a weak purity function
             *    }
             *
             *    static auto boo() {}   // typed as impure
             *    // Even though, boo cannot call any impure functions.
             *    // See also Expression::checkPurity().
             *  }
             */
            if (tf.purity == PURE.impure && (funcdecl.isNested() || funcdecl.isThis()))
            {
                FuncDeclaration fd = null;
                for (Dsymbol p = funcdecl.toParent2(); p; p = p.toParent2())
                {
                    if (AggregateDeclaration adx = p.isAggregateDeclaration())
                    {
                        if (adx.isNested())
                            continue;
                        break;
                    }
                    if ((fd = p.isFuncDeclaration()) !is null)
                        break;
                }

                /* If the parent's purity is inferred, then this function's purity needs
                 * to be inferred first.
                 */
                if (fd && fd.isPureBypassingInference() >= PURE.weak && !funcdecl.isInstantiated())
                {
                    tf.purity = PURE.fwdref; // default to pure
                }
            }
        }

        if (tf.isref)
            sc.stc |= STC.ref_;
        if (tf.isScopeQual)
            sc.stc |= STC.scope_;
        if (tf.isnothrow)
            sc.stc |= STC.nothrow_;
        if (tf.isnogc)
            sc.stc |= STC.nogc;
        if (tf.isproperty)
            sc.stc |= STC.property;
        if (tf.purity == PURE.fwdref)
            sc.stc |= STC.pure_;

        if (tf.trust != TRUST.default_)
        {
            sc.stc &= ~STC.safeGroup;
            if (tf.trust == TRUST.safe)
                sc.stc |= STC.safe;
            else if (tf.trust == TRUST.system)
                sc.stc |= STC.system;
            else if (tf.trust == TRUST.trusted)
                sc.stc |= STC.trusted;
        }

        if (funcdecl.isCtorDeclaration())
        {
            tf.isctor = true;
            Type tret = ad.handleType();
            assert(tret);
            tret = tret.addStorageClass(funcdecl.storage_class | sc.stc);
            tret = tret.addMod(funcdecl.type.mod);
            tf.next = tret;
            if (ad.isStructDeclaration())
                sc.stc |= STC.ref_;
        }

        // 'return' on a non-static class member function implies 'scope' as well
        if (ad && ad.isClassDeclaration() && (tf.isreturn || sc.stc & STC.return_) && !(sc.stc & STC.static_))
            sc.stc |= STC.scope_;

        // If 'this' has no pointers, remove 'scope' as it has no meaning
        // Note: this is already covered by semantic of `VarDeclaration` and `TypeFunction`,
        // but existing code relies on `hasPointers()` being called here to resolve forward references:
        // https://github.com/dlang/dmd/pull/14232#issuecomment-1162906573
        if (sc.stc & STC.scope_ && ad && ad.isStructDeclaration() && !ad.type.hasPointers())
        {
            sc.stc &= ~STC.scope_;
            tf.isScopeQual = false;
            if (tf.isreturnscope)
            {
                sc.stc &= ~(STC.return_ | STC.returnScope);
                tf.isreturn = false;
                tf.isreturnscope = false;
            }
        }

        sc.linkage = funcdecl._linkage;

        if (!tf.isNaked() && !(funcdecl.isThis() || funcdecl.isNested()))
        {
            import core.bitop : popcnt;
            auto mods = MODtoChars(tf.mod);
            .error(funcdecl.loc, "%s `%s` without `this` cannot be `%s`", funcdecl.kind, funcdecl.toPrettyChars, mods);
            if (tf.next && tf.next.ty != Tvoid && popcnt(tf.mod) == 1)
                .errorSupplemental(funcdecl.loc,
                    "did you mean to use `%s(%s)` as the return type?", mods, tf.next.toChars());

            tf.mod = 0; // remove qualifiers
        }

        /* Apply const, immutable, wild and shared storage class
         * to the function type. Do this before type semantic.
         */
        auto stc = funcdecl.storage_class;
        if (funcdecl.type.isImmutable())
            stc |= STC.immutable_;
        if (funcdecl.type.isConst())
            stc |= STC.const_;
        if (funcdecl.type.isShared() || funcdecl.storage_class & STC.synchronized_)
            stc |= STC.shared_;
        if (funcdecl.type.isWild())
            stc |= STC.wild;
        funcdecl.type = funcdecl.type.addSTC(stc);

        funcdecl.type = funcdecl.type.typeSemantic(funcdecl.loc, sc);
        sc = sc.pop();
    }

    auto f = getFunctionType(funcdecl);
    if (!f)
        return;     // funcdecl's type is not a function

    {
        // Merge back function attributes into 'originalType'.
        // It's used for mangling, ddoc, and json output.
        TypeFunction tfo = funcdecl.originalType.toTypeFunction();
        tfo.mod = f.mod;
        tfo.isScopeQual = f.isScopeQual;
        tfo.isreturninferred = f.isreturninferred;
        tfo.isscopeinferred = f.isscopeinferred;
        tfo.isref = f.isref;
        tfo.isnothrow = f.isnothrow;
        tfo.isnogc = f.isnogc;
        tfo.isproperty = f.isproperty;
        tfo.purity = f.purity;
        tfo.trust = f.trust;

        funcdecl.storage_class &= ~(STC.TYPECTOR | STC.FUNCATTR);
    }

    // check pragma(crt_constructor) signature
    if (funcdecl.isCrtCtor || funcdecl.isCrtDtor)
    {
        const idStr = funcdecl.isCrtCtor ? "crt_constructor" : "crt_destructor";
        if (f.nextOf().ty != Tvoid)
            .error(funcdecl.loc, "%s `%s` must return `void` for `pragma(%s)`", funcdecl.kind, funcdecl.toPrettyChars, idStr.ptr);
        if (funcdecl._linkage != LINK.c && f.parameterList.length != 0)
            .error(funcdecl.loc, "%s `%s` must be `extern(C)` for `pragma(%s)` when taking parameters", funcdecl.kind, funcdecl.toPrettyChars, idStr.ptr);
        if (funcdecl.isThis())
            .error(funcdecl.loc, "%s `%s` cannot be a non-static member function for `pragma(%s)`", funcdecl.kind, funcdecl.toPrettyChars, idStr.ptr);
    }

    if (funcdecl.overnext && funcdecl.isCsymbol())
    {
        /* C does not allow function overloading, but it does allow
         * redeclarations of the same function. If .overnext points
         * to a redeclaration, ok. Error if it is an overload.
         */
        auto fnext = funcdecl.overnext.isFuncDeclaration();
        funcDeclarationSemantic(sc, fnext);
        auto fn = fnext.type.isTypeFunction();
        if (!fn || !cFuncEquivalence(f, fn))
        {
            .error(funcdecl.loc, "%s `%s` redeclaration with different type", funcdecl.kind, funcdecl.toPrettyChars);
            //printf("t1: %s\n", f.toChars());
            //printf("t2: %s\n", fn.toChars());
        }
        funcdecl.overnext = null;   // don't overload the redeclarations
    }

    if ((funcdecl.storage_class & STC.auto_) && !f.isref && !funcdecl.inferRetType)
        .error(funcdecl.loc, "%s `%s` storage class `auto` has no effect if return type is not inferred", funcdecl.kind, funcdecl.toPrettyChars);

    if (f.isreturn && !funcdecl.needThis() && !funcdecl.isNested())
    {
        /* Non-static nested functions have a hidden 'this' pointer to which
         * the 'return' applies
         */
        if (sc.scopesym && sc.scopesym.isAggregateDeclaration())
            .error(funcdecl.loc, "%s `%s` `static` member has no `this` to which `return` can apply", funcdecl.kind, funcdecl.toPrettyChars);
        else
            error(funcdecl.loc, "top-level function `%s` has no `this` to which `return` can apply", funcdecl.toChars());
    }

    if (funcdecl.isAbstract() && !funcdecl.isVirtual())
    {
        const(char)* sfunc;
        if (funcdecl.isStatic())
            sfunc = "static";
        else if (funcdecl.visibility.kind == Visibility.Kind.private_ || funcdecl.visibility.kind == Visibility.Kind.package_)
            sfunc = visibilityToChars(funcdecl.visibility.kind);
        else
            sfunc = "final";
        .error(funcdecl.loc, "%s `%s` `%s` functions cannot be `abstract`", funcdecl.kind, funcdecl.toPrettyChars, sfunc);
    }

    if (funcdecl.isOverride() && !funcdecl.isVirtual() && !funcdecl.isFuncLiteralDeclaration())
    {
        Visibility.Kind kind = funcdecl.visible().kind;
        if ((kind == Visibility.Kind.private_ || kind == Visibility.Kind.package_) && funcdecl.isMember())
            .error(funcdecl.loc, "%s `%s` `%s` method is not virtual and cannot override", funcdecl.kind, funcdecl.toPrettyChars, visibilityToChars(kind));
        else
            .error(funcdecl.loc, "%s `%s` cannot override a non-virtual function", funcdecl.kind, funcdecl.toPrettyChars);
    }

    if (funcdecl.isAbstract() && funcdecl.isFinalFunc())
        .error(funcdecl.loc, "%s `%s` cannot be both `final` and `abstract`", funcdecl.kind, funcdecl.toPrettyChars);

    if (funcdecl.printf || funcdecl.scanf)
    {
        checkPrintfScanfSignature(funcdecl, f, sc);
    }

    if (auto id = parent.isInterfaceDeclaration())
    {
        funcdecl.storage_class |= STC.abstract_;
        if (funcdecl.isCtorDeclaration() || funcdecl.isPostBlitDeclaration() || funcdecl.isDtorDeclaration() || funcdecl.isInvariantDeclaration() || funcdecl.isNewDeclaration() || funcdecl.isDelete())
            .error(funcdecl.loc, "%s `%s` constructors, destructors, postblits, invariants, new and delete functions are not allowed in interface `%s`", funcdecl.kind, funcdecl.toPrettyChars, id.toChars());
        if (funcdecl.fbody && funcdecl.isVirtual())
            .error(funcdecl.loc, "%s `%s` function body only allowed in `final` functions in interface `%s`", funcdecl.kind, funcdecl.toPrettyChars, id.toChars());
    }

    if (UnionDeclaration ud = parent.isUnionDeclaration())
    {
        if (funcdecl.isPostBlitDeclaration() || funcdecl.isDtorDeclaration() || funcdecl.isInvariantDeclaration())
            .error(funcdecl.loc, "%s `%s` destructors, postblits and invariants are not allowed in union `%s`", funcdecl.kind, funcdecl.toPrettyChars, ud.toChars());
    }

    if (StructDeclaration sd = parent.isStructDeclaration())
    {
        if (funcdecl.isCtorDeclaration())
        {
            goto Ldone;
        }
    }

    if (ClassDeclaration cd = parent.isClassDeclaration())
    {
        parent = cd = objc.getParent(funcdecl, cd);

        if (funcdecl.isCtorDeclaration())
        {
            goto Ldone;
        }

        if (funcdecl.storage_class & STC.abstract_)
            cd.isabstract = ThreeState.yes;

        // if static function, do not put in vtbl[]
        if (!funcdecl.isVirtual())
        {
            //printf("\tnot virtual\n");
            goto Ldone;
        }
        // Suppress further errors if the return type is an error
        if (funcdecl.type.nextOf() == Type.terror)
            goto Ldone;

        bool may_override = false;
        for (size_t i = 0; i < cd.baseclasses.length; i++)
        {
            BaseClass* b = (*cd.baseclasses)[i];
            ClassDeclaration cbd = b.type.toBasetype().isClassHandle();
            if (!cbd)
                continue;
            for (size_t j = 0; j < cbd.vtbl.length; j++)
            {
                FuncDeclaration f2 = cbd.vtbl[j].isFuncDeclaration();
                if (!f2 || f2.ident != funcdecl.ident)
                    continue;
                if (cbd.parent && cbd.parent.isTemplateInstance())
                {
                    if (!functionSemantic(f2))
                        goto Ldone;
                }
                may_override = true;
            }
        }
        if (may_override && funcdecl.type.nextOf() is null)
        {
            /* If same name function exists in base class but 'this' is auto return,
             * cannot find index of base class's vtbl[] to override.
             */
            .error(funcdecl.loc, "%s `%s` return type inference is not supported if may override base class function", funcdecl.kind, funcdecl.toPrettyChars);
        }

        /* Find index of existing function in base class's vtbl[] to override
         * (the index will be the same as in cd's current vtbl[])
         */
        int vi = cd.baseClass ? funcdecl.findVtblIndex(&cd.baseClass.vtbl, cast(int)cd.baseClass.vtbl.length) : -1;

        bool doesoverride = false;
        switch (vi)
        {
        case -1:
        Lintro:
            /* Didn't find one, so
             * This is an 'introducing' function which gets a new
             * slot in the vtbl[].
             */

            // Verify this doesn't override previous final function
            if (cd.baseClass)
            {
                Dsymbol s = cd.baseClass.search(funcdecl.loc, funcdecl.ident);
                if (s)
                {
                    if (auto f2 = s.isFuncDeclaration())
                    {
                        f2 = f2.overloadExactMatch(funcdecl.type);
                        if (f2 && f2.isFinalFunc() && f2.visible().kind != Visibility.Kind.private_)
                            .error(funcdecl.loc, "%s `%s` cannot override `final` function `%s`", funcdecl.kind, funcdecl.toPrettyChars, f2.toPrettyChars());
                    }
                }
            }

            /* These quirky conditions mimic what happens when virtual
               inheritance is implemented by producing a virtual base table
               with offsets to each of the virtual bases.
             */
            if (target.cpp.splitVBasetable && cd.classKind == ClassKind.cpp &&
                cd.baseClass && cd.baseClass.vtbl.length)
            {
                /* if overriding an interface function, then this is not
                 * introducing and don't put it in the class vtbl[]
                 */
                funcdecl.interfaceVirtual = funcdecl.overrideInterface();
                if (funcdecl.interfaceVirtual)
                {
                    //printf("\tinterface function %s\n", toChars());
                    cd.vtblFinal.push(funcdecl);
                    goto Linterfaces;
                }
            }

            if (funcdecl.isFinalFunc())
            {
                // Don't check here, as it may override an interface function
                //if (isOverride())
                //    error("is marked as override, but does not override any function");
                cd.vtblFinal.push(funcdecl);
            }
            else
            {
                //printf("\tintroducing function %s\n", funcdecl.toChars());
                funcdecl.isIntroducing = true;
                if (cd.classKind == ClassKind.cpp && target.cpp.reverseOverloads)
                {
                    /* Overloaded functions with same name are grouped and in reverse order.
                     * Search for first function of overload group, and insert
                     * funcdecl into vtbl[] immediately before it.
                     */
                    funcdecl.vtblIndex = cast(int)cd.vtbl.length;
                    bool found;
                    foreach (const i, s; cd.vtbl)
                    {
                        if (found)
                            // the rest get shifted forward
                            ++s.isFuncDeclaration().vtblIndex;
                        else if (s.ident == funcdecl.ident && s.parent == parent)
                        {
                            // found first function of overload group
                            funcdecl.vtblIndex = cast(int)i;
                            found = true;
                            ++s.isFuncDeclaration().vtblIndex;
                        }
                    }
                    cd.vtbl.insert(funcdecl.vtblIndex, funcdecl);

                    debug foreach (const i, s; cd.vtbl)
                    {
                        // a C++ dtor gets its vtblIndex later (and might even be added twice to the vtbl),
                        // e.g. when compiling druntime with a debug compiler, namely with core.stdcpp.exception.
                        if (auto fd = s.isFuncDeclaration())
                            assert(fd.vtblIndex == i ||
                                   (cd.classKind == ClassKind.cpp && fd.isDtorDeclaration) ||
                                   funcdecl.parent.isInterfaceDeclaration); // interface functions can be in multiple vtbls
                    }
                }
                else
                {
                    // Append to end of vtbl[]
                    vi = cast(int)cd.vtbl.length;
                    cd.vtbl.push(funcdecl);
                    funcdecl.vtblIndex = vi;
                }
            }
            break;

        case -2:
            // can't determine because of forward references
            funcdecl.errors = true;
            return;

        default:
            {
                if (vi >= cd.vtbl.length)
                {
                    /* the derived class cd doesn't have its vtbl[] allocated yet.
                     * https://issues.dlang.org/show_bug.cgi?id=21008
                     */
                    .error(funcdecl.loc, "%s `%s` circular reference to class `%s`", funcdecl.kind, funcdecl.toPrettyChars, cd.toChars());
                    funcdecl.errors = true;
                    return;
                }
                FuncDeclaration fdv = cd.baseClass.vtbl[vi].isFuncDeclaration();
                FuncDeclaration fdc = cd.vtbl[vi].isFuncDeclaration();
                // This function is covariant with fdv

                if (fdc == funcdecl)
                {
                    doesoverride = true;
                    break;
                }

                auto vtf = getFunctionType(fdv);
                if (vtf.trust > TRUST.system && f.trust == TRUST.system)
                    .error(funcdecl.loc, "%s `%s` cannot override `@safe` method `%s` with a `@system` attribute", funcdecl.kind, funcdecl.toPrettyChars,
                                   fdv.toPrettyChars);

                if (fdc.toParent() == parent)
                {
                    //printf("vi = %d,\tthis = %p %s %s @ [%s]\n\tfdc  = %p %s %s @ [%s]\n\tfdv  = %p %s %s @ [%s]\n",
                    //        vi, this, this.toChars(), this.type.toChars(), this.loc.toChars(),
                    //            fdc,  fdc .toChars(), fdc .type.toChars(), fdc .loc.toChars(),
                    //            fdv,  fdv .toChars(), fdv .type.toChars(), fdv .loc.toChars());

                    // fdc overrides fdv exactly, then this introduces new function.
                    if (fdc.type.mod == fdv.type.mod && funcdecl.type.mod != fdv.type.mod)
                        goto Lintro;
                }

                if (fdv.isDeprecated && !funcdecl.isDeprecated)
                    deprecation(funcdecl.loc, "`%s` is overriding the deprecated method `%s`",
                                funcdecl.toPrettyChars, fdv.toPrettyChars);

                // This function overrides fdv
                if (fdv.isFinalFunc())
                    .error(funcdecl.loc, "%s `%s` cannot override `final` function `%s`", funcdecl.kind, funcdecl.toPrettyChars, fdv.toPrettyChars());

                if (!funcdecl.isOverride())
                {
                    if (fdv.isFuture())
                    {
                        deprecation(funcdecl.loc, "`@__future` base class method `%s` is being overridden by `%s`; rename the latter", fdv.toPrettyChars(), funcdecl.toPrettyChars());
                        // Treat 'this' as an introducing function, giving it a separate hierarchy in the vtbl[]
                        goto Lintro;
                    }
                    else
                    {
                        // https://issues.dlang.org/show_bug.cgi?id=17349
                        error(funcdecl.loc, "cannot implicitly override base class method `%s` with `%s`; add `override` attribute",
                              fdv.toPrettyChars(), funcdecl.toPrettyChars());
                    }
                }
                doesoverride = true;
                if (fdc.toParent() == parent)
                {
                    // If both are mixins, or both are not, then error.
                    // If either is not, the one that is not overrides the other.
                    bool thismixin = funcdecl.parent.isClassDeclaration() !is null;
                    bool fdcmixin = fdc.parent.isClassDeclaration() !is null;
                    if (thismixin == fdcmixin)
                    {
                        .error(funcdecl.loc, "%s `%s` multiple overrides of same function", funcdecl.kind, funcdecl.toPrettyChars);
                    }
                    /*
                     * https://issues.dlang.org/show_bug.cgi?id=711
                     *
                     * If an overriding method is introduced through a mixin,
                     * we need to update the vtbl so that both methods are
                     * present.
                     */
                    else if (thismixin)
                    {
                        /* if the mixin introduced the overriding method, then reintroduce it
                         * in the vtbl. The initial entry for the mixined method
                         * will be updated at the end of the enclosing `if` block
                         * to point to the current (non-mixined) function.
                         */
                        auto vitmp = cast(int)cd.vtbl.length;
                        cd.vtbl.push(fdc);
                        fdc.vtblIndex = vitmp;
                    }
                    else if (fdcmixin)
                    {
                        /* if the current overriding function is coming from a
                         * mixined block, then push the current function in the
                         * vtbl, but keep the previous (non-mixined) function as
                         * the overriding one.
                         */
                        auto vitmp = cast(int)cd.vtbl.length;
                        cd.vtbl.push(funcdecl);
                        funcdecl.vtblIndex = vitmp;
                        break;
                    }
                    else // fdc overrides fdv
                    {
                        // this doesn't override any function
                        break;
                    }
                }
                cd.vtbl[vi] = funcdecl;
                funcdecl.vtblIndex = vi;

                /* Remember which functions this overrides
                 */
                funcdecl.foverrides.push(fdv);

                /* This works by whenever this function is called,
                 * it actually returns tintro, which gets dynamically
                 * cast to type. But we know that tintro is a base
                 * of type, so we could optimize it by not doing a
                 * dynamic cast, but just subtracting the isBaseOf()
                 * offset if the value is != null.
                 */

                if (fdv.tintro)
                    funcdecl.tintro = fdv.tintro;
                else if (!funcdecl.type.equals(fdv.type))
                {
                    auto tnext = funcdecl.type.nextOf();
                    if (auto handle = tnext.isClassHandle())
                    {
                        if (handle.semanticRun < PASS.semanticdone && !handle.isBaseInfoComplete())
                            handle.dsymbolSemantic(null);
                    }
                    /* Only need to have a tintro if the vptr
                     * offsets differ
                     */
                    int offset;
                    if (fdv.type.nextOf().isBaseOf(tnext, &offset))
                    {
                        funcdecl.tintro = fdv.type;
                    }
                }
                break;
            }
        }

        /* Go through all the interface bases.
         * If this function is covariant with any members of those interface
         * functions, set the tintro.
         */
    Linterfaces:
        bool foundVtblMatch = false;

        for (ClassDeclaration bcd = cd; !foundVtblMatch && bcd; bcd = bcd.baseClass)
        {
            foreach (b; bcd.interfaces)
            {
                vi = funcdecl.findVtblIndex(&b.sym.vtbl, cast(int)b.sym.vtbl.length);
                switch (vi)
                {
                case -1:
                    break;

                case -2:
                    // can't determine because of forward references
                    funcdecl.errors = true;
                    return;

                default:
                    {
                        auto fdv = cast(FuncDeclaration)b.sym.vtbl[vi];
                        Type ti = null;

                        foundVtblMatch = true;

                        /* Remember which functions this overrides
                         */
                        funcdecl.foverrides.push(fdv);

                        if (fdv.tintro)
                            ti = fdv.tintro;
                        else if (!funcdecl.type.equals(fdv.type))
                        {
                            /* Only need to have a tintro if the vptr
                             * offsets differ
                             */
                            int offset;
                            if (fdv.type.nextOf().isBaseOf(funcdecl.type.nextOf(), &offset))
                            {
                                ti = fdv.type;
                            }
                        }
                        if (ti)
                        {
                            if (funcdecl.tintro)
                            {
                                if (!funcdecl.tintro.nextOf().equals(ti.nextOf()) && !funcdecl.tintro.nextOf().isBaseOf(ti.nextOf(), null) && !ti.nextOf().isBaseOf(funcdecl.tintro.nextOf(), null))
                                {
                                    .error(funcdecl.loc, "%s `%s` incompatible covariant types `%s` and `%s`", funcdecl.kind, funcdecl.toPrettyChars, funcdecl.tintro.toChars(), ti.toChars());
                                }
                            }
                            else
                            {
                                funcdecl.tintro = ti;
                            }
                        }
                    }
                }
            }
        }
        if (foundVtblMatch)
        {
            goto L2;
        }

        if (!doesoverride && funcdecl.isOverride() && (funcdecl.type.nextOf() || !may_override))
        {
            BaseClass* bc = null;
            Dsymbol s = null;
            for (size_t i = 0; i < cd.baseclasses.length; i++)
            {
                bc = (*cd.baseclasses)[i];
                s = bc.sym.search_correct(funcdecl.ident);
                if (s)
                    break;
            }

            if (s)
            {
                HdrGenState hgs;
                OutBuffer buf;

                auto fd = s.isFuncDeclaration();
                functionToBufferFull(cast(TypeFunction)(funcdecl.type), buf,
                    new Identifier(funcdecl.toPrettyChars()), hgs, null);
                const(char)* funcdeclToChars = buf.peekChars();

                if (fd)
                {
                    OutBuffer buf1;

                    if (fd.ident == funcdecl.ident)
                        hgs.fullQual = true;

                    // https://issues.dlang.org/show_bug.cgi?id=23745
                    // If the potentially overridden function contains errors,
                    // inform the user to fix that one first
                    if (fd.errors)
                    {
                        error(funcdecl.loc, "function `%s` does not override any function, did you mean to override `%s`?",
                            funcdecl.toChars(), fd.toPrettyChars());
                        errorSupplemental(fd.loc, "Function `%s` contains errors in its declaration, therefore it cannot be correctly overridden",
                            fd.toPrettyChars());
                    }
                    else
                    {
                        functionToBufferFull(cast(TypeFunction)(fd.type), buf1,
                            new Identifier(fd.toPrettyChars()), hgs, null);

                        error(funcdecl.loc, "function `%s` does not override any function, did you mean to override `%s`?",
                            funcdeclToChars, buf1.peekChars());
                   }
                }
                else
                {
                    error(funcdecl.loc, "function `%s` does not override any function, did you mean to override %s `%s`?",
                        funcdeclToChars, s.kind, s.toPrettyChars());
                    errorSupplemental(funcdecl.loc, "Functions are the only declarations that may be overridden");
                }
            }
            else
                .error(funcdecl.loc, "%s `%s` does not override any function", funcdecl.kind, funcdecl.toPrettyChars);
        }

    L2:
        objc.setSelector(funcdecl, sc);
        objc.checkLinkage(funcdecl);
        objc.addToClassMethodList(funcdecl, cd);
        objc.setAsOptional(funcdecl, sc);

        /* Go through all the interface bases.
         * Disallow overriding any final functions in the interface(s).
         */
        foreach (b; cd.interfaces)
        {
            if (b.sym)
            {
                if (auto s = search_function(b.sym, funcdecl.ident))
                {
                    if (auto f2 = s.isFuncDeclaration())
                    {
                        f2 = f2.overloadExactMatch(funcdecl.type);
                        if (f2 && f2.isFinalFunc() && f2.visible().kind != Visibility.Kind.private_)
                            .error(funcdecl.loc, "%s `%s` cannot override `final` function `%s.%s`", funcdecl.kind, funcdecl.toPrettyChars, b.sym.toChars(), f2.toPrettyChars());
                    }
                }
            }
        }

        if (funcdecl.isOverride)
        {
            if (funcdecl.storage_class & STC.disable)
                deprecation(funcdecl.loc,
                            "`%s` cannot be annotated with `@disable` because it is overriding a function in the base class",
                            funcdecl.toPrettyChars);

            if (funcdecl.isDeprecated && !(funcdecl.foverrides.length && funcdecl.foverrides[0].isDeprecated))
                deprecation(funcdecl.loc,
                            "`%s` cannot be marked as `deprecated` because it is overriding a function in the base class",
                            funcdecl.toPrettyChars);
        }

    }
    else if (funcdecl.isOverride() && !parent.isTemplateInstance())
        .error(funcdecl.loc, "%s `%s` `override` only applies to class member functions", funcdecl.kind, funcdecl.toPrettyChars);

    if (auto ti = parent.isTemplateInstance)
    {
        objc.setSelector(funcdecl, sc);
        objc.setAsOptional(funcdecl, sc);
    }

    objc.validateSelector(funcdecl);
    objc.validateOptional(funcdecl);
    // Reflect this.type to f because it could be changed by findVtblIndex
    f = funcdecl.type.toTypeFunction();

Ldone:
    if (!funcdecl.fbody && !funcdecl.allowsContractWithoutBody())
        .error(funcdecl.loc, "%s `%s` `in` and `out` contracts can only appear without a body when they are virtual interface functions or abstract", funcdecl.kind, funcdecl.toPrettyChars);

    /* Do not allow template instances to add virtual functions
     * to a class.
     */
    if (funcdecl.isVirtual())
    {
        if (auto ti = parent.isTemplateInstance())
        {
            // Take care of nested templates
            while (1)
            {
                TemplateInstance ti2 = ti.tempdecl.parent.isTemplateInstance();
                if (!ti2)
                    break;
                ti = ti2;
            }

            // If it's a member template
            ClassDeclaration cd = ti.tempdecl.isClassMember();
            if (cd)
            {
                .error(funcdecl.loc, "%s `%s` cannot use template to add virtual function to class `%s`", funcdecl.kind, funcdecl.toPrettyChars, cd.toChars());
            }
        }
    }

    funcdecl.checkMain();       // Check main() parameters and return type

    /* Purity and safety can be inferred for some functions by examining
     * the function body.
     */
    if (funcdecl.canInferAttributes(sc))
        funcdecl.initInferAttributes();

    funcdecl.semanticRun = PASS.semanticdone;

    /* Save scope for possible later use (if we need the
     * function internals)
     */
    funcdecl._scope = sc.copy();
    funcdecl._scope.setNoFree();

    __gshared bool printedMain = false; // semantic might run more than once
    if (global.params.v.verbose && !printedMain)
    {
        const(char)* type = funcdecl.isMain() ? "main" : funcdecl.isWinMain() ? "winmain" : funcdecl.isDllMain() ? "dllmain" : cast(const(char)*)null;
        Module mod = sc._module;

        if (type && mod)
        {
            printedMain = true;
            auto name = mod.srcfile.toChars();
            auto path = FileName.searchPath(global.path, name, true);
            message("entry     %-10s\t%s", type, path ? path : name);
        }
    }

    if (funcdecl.fbody && sc._module.isRoot() &&
        (funcdecl.isMain() || funcdecl.isWinMain() || funcdecl.isDllMain() || funcdecl.isCMain()))
        global.hasMainFunction = true;

    if (funcdecl.fbody && funcdecl.isMain() && sc._module.isRoot())
    {
        // check if `_d_cmain` is defined
        bool cmainTemplateExists()
        {
            Dsymbol pscopesym;
            auto rootSymbol = sc.search(funcdecl.loc, Id.empty, pscopesym);
            if (auto moduleSymbol = rootSymbol.search(funcdecl.loc, Id.object))
                if (moduleSymbol.search(funcdecl.loc, Id.CMain))
                    return true;

            return false;
        }

        // Only mixin `_d_cmain` if it is defined
        if (cmainTemplateExists())
        {
            // add `mixin _d_cmain!();` to the declaring module
            auto tqual = new TypeIdentifier(funcdecl.loc, Id.CMain);
            auto tm = new TemplateMixin(funcdecl.loc, null, tqual, null);
            sc._module.members.push(tm);
        }
    }

    assert(funcdecl.type.ty != Terror || funcdecl.errors);

    // semantic for parameters' UDAs
    foreach (i, param; f.parameterList)
    {
        if (param && param.userAttribDecl)
            param.userAttribDecl.dsymbolSemantic(sc);
    }
}


/****************************************************
 * Resolve forward reference of function signature -
 * parameter types, return type, and attributes.
 * Params:
 *  fd = function declaration
 * Returns:
 *  false if any errors exist in the signature.
 */
public
extern (C++)
bool functionSemantic(FuncDeclaration fd)
{
    //printf("functionSemantic() %p %s\n", this, toChars());
    if (!fd._scope)
        return !fd.errors;

    fd.cppnamespace = fd._scope.namespace;

    if (!fd.originalType) // semantic not yet run
    {
        TemplateInstance spec = fd.isSpeculative();
        uint olderrs = global.errors;
        uint oldgag = global.gag;
        if (global.gag && !spec)
            global.gag = 0;
        dsymbolSemantic(fd, fd._scope);
        global.gag = oldgag;
        if (spec && global.errors != olderrs)
            spec.errors = (global.errors - olderrs != 0);
        if (olderrs != global.errors) // if errors compiling this function
            return false;
    }

    // if inferring return type, sematic3 needs to be run
    // - When the function body contains any errors, we cannot assume
    //   the inferred return type is valid.
    //   So, the body errors should become the function signature error.
    if (fd.inferRetType && fd.type && !fd.type.nextOf())
        return fd.functionSemantic3();

    TemplateInstance ti;
    if (fd.isInstantiated() && !fd.isVirtualMethod() &&
        ((ti = fd.parent.isTemplateInstance()) is null || ti.isTemplateMixin() || ti.tempdecl.ident == fd.ident))
    {
        AggregateDeclaration ad = fd.isMemberLocal();
        if (ad && ad.sizeok != Sizeok.done)
        {
            /* Currently dmd cannot resolve forward references per methods,
             * then setting SIZOKfwd is too conservative and would break existing code.
             * So, just stop method attributes inference until ad.dsymbolSemantic() done.
             */
            //ad.sizeok = Sizeok.fwd;
        }
        else
            return fd.functionSemantic3() || !fd.errors;
    }

    if (fd.storage_class & STC.inference)
        return fd.functionSemantic3() || !fd.errors;

    return !fd.errors;
}

/****************************************************
 * Resolve forward reference of function body.
 * Returns false if any errors exist in the body.
 */
public
extern (C++)
bool functionSemantic3(FuncDeclaration fd)
{
    if (fd.semanticRun < PASS.semantic3 && fd._scope)
    {
        /* Forward reference - we need to run semantic3 on this function.
         * If errors are gagged, and it's not part of a template instance,
         * we need to temporarily ungag errors.
         */
        TemplateInstance spec = fd.isSpeculative();
        uint olderrs = global.errors;
        uint oldgag = global.gag;
        if (global.gag && !spec)
            global.gag = 0;
        semantic3(fd, fd._scope);
        global.gag = oldgag;

        // If it is a speculatively-instantiated template, and errors occur,
        // we need to mark the template as having errors.
        if (spec && global.errors != olderrs)
            spec.errors = (global.errors - olderrs != 0);
        if (olderrs != global.errors) // if errors compiling this function
            return false;
    }

    return !fd.errors && !fd.hasSemantic3Errors();
}

// called from semantic3
/**
 * Creates and returns the hidden parameters for this function declaration.
 *
 * Hidden parameters include the `this` parameter of a class, struct or
 * nested function and the selector parameter for Objective-C methods.
 */
extern (D) void declareThis(FuncDeclaration fd, Scope* sc)
{
    const bool dualCtx = (fd.toParent2() != fd.toParentLocal());
    if (dualCtx)
        fd.hasDualContext = true;
    auto ad = fd.isThis();
    if (!dualCtx && !ad && !fd.isNested())
    {
        fd.vthis = null;
        fd.objc.selectorParameter = null;
        return;
    }

    Type addModStc(Type t)
    {
        return t.addMod(fd.type.mod).addStorageClass(fd.storage_class);
    }

    if (dualCtx || fd.isNested())
    {
        /* The 'this' for a nested function is the link to the
         * enclosing function's stack frame.
         * Note that nested functions and member functions are disjoint.
         */
        Type tthis = addModStc(dualCtx ?
                               Type.tvoidptr.sarrayOf(2).pointerTo() :
                               Type.tvoid.pointerTo());
        fd.vthis = new VarDeclaration(fd.loc, tthis, dualCtx ? Id.this2 : Id.capture, null);
        fd.vthis.storage_class |= STC.parameter | STC.nodtor;
    }
    else if (ad)
    {
        Type thandle = addModStc(ad.handleType());
        fd.vthis = new ThisDeclaration(fd.loc, thandle);
        fd.vthis.storage_class |= STC.parameter;
        if (thandle.ty == Tstruct)
        {
            fd.vthis.storage_class |= STC.ref_;
        }
    }

    if (auto tf = fd.type.isTypeFunction())
    {
        if (tf.isreturn)
            fd.vthis.storage_class |= STC.return_;
        if (tf.isScopeQual)
            fd.vthis.storage_class |= STC.scope_;
        if (tf.isreturnscope)
            fd.vthis.storage_class |= STC.returnScope;
    }

    fd.vthis.dsymbolSemantic(sc);
    if (!sc.insert(fd.vthis))
        assert(0);
    fd.vthis.parent = fd;
    if (ad)
        fd.objc.selectorParameter = .objc.createSelectorParameter(fd, sc);
}