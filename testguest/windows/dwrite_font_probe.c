/* Owned API-level probe for the DirectWrite path used by Skia. */
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <dwrite.h>
#include <stdio.h>
#include <string.h>

static int install_wine_fonts(void)
{
    const WCHAR *keys[] = {L"Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", L"Software\\Microsoft\\Windows\\CurrentVersion\\Fonts"};
    const WCHAR *names[] = {L"Tahoma (TrueType)", L"Tahoma Bold (TrueType)"};
    const WCHAR *files[] = {L"tahoma.ttf", L"tahomabd.ttf"};
    for (unsigned k=0;k<2;k++) {
        HKEY key=NULL;
        LONG err=RegOpenKeyExW(HKEY_LOCAL_MACHINE,keys[k],0,KEY_SET_VALUE,&key);
        if (err) { printf("DWRITE registration open error=%ld\n",err); return 1; }
        for (unsigned i=0;i<2;i++) {
            WCHAR path[MAX_PATH];
            GetWindowsDirectoryW(path,MAX_PATH); lstrcatW(path,L"\\Fonts\\"); lstrcatW(path,files[i]);
            if (GetFileAttributesW(path)==INVALID_FILE_ATTRIBUTES) { RegCloseKey(key); return 1; }
            err=RegSetValueExW(key,names[i],0,REG_SZ,(const BYTE *)files[i],(lstrlenW(files[i])+1)*sizeof(WCHAR));
            if (err) { RegCloseKey(key); return 1; }
        }
        RegCloseKey(key);
    }
    /* Wine-supported aliases: retain any explicit user replacements. */
    HKEY replacements=NULL;
    LONG err=RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Wine\\Fonts\\Replacements",0,NULL,0,
        KEY_QUERY_VALUE|KEY_SET_VALUE,NULL,&replacements,NULL);
    if (err) return 1;
    const WCHAR *aliases[]={L"Arial",L"sans",L"Segoe UI",L"Microsoft Sans Serif"};
    const WCHAR fallback[]=L"Tahoma";
    for (unsigned i=0;i<sizeof(aliases)/sizeof(aliases[0]);i++) {
        err=RegQueryValueExW(replacements,aliases[i],NULL,NULL,NULL,NULL);
        if (err==ERROR_FILE_NOT_FOUND)
            err=RegSetValueExW(replacements,aliases[i],0,REG_SZ,(const BYTE *)fallback,sizeof(fallback));
        if (err) { RegCloseKey(replacements); return 1; }
    }
    RegCloseKey(replacements);
    puts("DWRITE registered bundled Wine Tahoma files and missing fallback aliases");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc==2 && !strcmp(argv[1],"--install-wine-fonts") && install_wine_fonts()) return 2;
    IDWriteFactory *factory = NULL;
    IDWriteFontCollection *collection = NULL;
    IDWriteGdiInterop *interop = NULL;
    HRESULT hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, (IUnknown **)&factory);
    printf("DWRITE factory hr=%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;
    hr = IDWriteFactory_GetSystemFontCollection(factory, &collection, FALSE);
    UINT32 count = SUCCEEDED(hr) ? IDWriteFontCollection_GetFontFamilyCount(collection) : 0;
    printf("DWRITE collection hr=%08lx families=%u\n", (unsigned long)hr, count);
    int failures = FAILED(hr) || !count;
    if (collection) {
        const WCHAR *names[] = {L"Tahoma", L"Arial", L"Segoe UI", L"sans"};
        for (unsigned i=0; i<sizeof(names)/sizeof(names[0]); i++) {
            UINT32 index=0; BOOL exists=FALSE;
            hr=IDWriteFontCollection_FindFamilyName(collection,names[i],&index,&exists);
            printf("DWRITE family %u hr=%08lx exists=%d index=%u\n",i,(unsigned long)hr,exists,index);
            if ((i==0 || argc==2) && (FAILED(hr) || !exists)) failures++;
            if (SUCCEEDED(hr) && exists) {
                IDWriteFontFamily *family=NULL; IDWriteFont *font=NULL; IDWriteFontFace *face=NULL;
                hr=IDWriteFontCollection_GetFontFamily(collection,index,&family);
                if (SUCCEEDED(hr)) hr=IDWriteFontFamily_GetFirstMatchingFont(family,DWRITE_FONT_WEIGHT_NORMAL,DWRITE_FONT_STRETCH_NORMAL,DWRITE_FONT_STYLE_NORMAL,&font);
                if (SUCCEEDED(hr)) hr=IDWriteFont_CreateFontFace(font,&face);
                printf("DWRITE face %u hr=%08lx glyphs=%u\n",i,(unsigned long)hr,face ? IDWriteFontFace_GetGlyphCount(face) : 0);
                if (FAILED(hr)) failures++;
                if (face) {
                    UINT32 cp='S'; UINT16 glyph=0; DWRITE_FONT_METRICS metrics={0};
                    IDWriteFontFace_GetMetrics(face,&metrics);
                    hr=IDWriteFontFace_GetGlyphIndices(face,&cp,1,&glyph);
                    printf("DWRITE glyph %u hr=%08lx glyph=%u em=%u ascent=%u\n",i,(unsigned long)hr,glyph,metrics.designUnitsPerEm,metrics.ascent);
                    if (FAILED(hr) || !glyph || !metrics.designUnitsPerEm) failures++;
                    IDWriteFontFace_Release(face);
                }
                if (font) IDWriteFont_Release(font);
                if (family) IDWriteFontFamily_Release(family);
            }
        }
        IDWriteFontCollection_Release(collection);
    }
    hr=IDWriteFactory_GetGdiInterop(factory,&interop);
    printf("DWRITE interop hr=%08lx\n",(unsigned long)hr);
    if (SUCCEEDED(hr)) {
        LOGFONTW lf={0}; IDWriteFont *font=NULL;
        lf.lfHeight=-13; lf.lfWeight=FW_NORMAL; lstrcpyW(lf.lfFaceName,L"Tahoma");
        hr=IDWriteGdiInterop_CreateFontFromLOGFONT(interop,&lf,&font);
        printf("DWRITE GDI font hr=%08lx\n",(unsigned long)hr);
        if (FAILED(hr)) failures++;
        if (font) IDWriteFont_Release(font);
        IDWriteGdiInterop_Release(interop);
    } else failures++;
    IDWriteFactory_Release(factory);
    printf("DWRITE %s failures=%d\n",failures ? "FAIL" : "PASS",failures);
    fflush(stdout);
    return failures ? 1 : 0;
}
