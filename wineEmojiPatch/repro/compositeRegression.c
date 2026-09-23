#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <usp10.h>
#include <stdio.h>
#include <string.h>

struct sample { const char *name; const WCHAR *text; BOOL single; };
static const struct sample samples[] = {
    {"plain", L"A\x4e2d\x6587 0123", FALSE},
    {"smile", L"\xd83d\xde00", TRUE},
    {"thumb", L"\xd83d\xdc4d", TRUE},
    {"thumb-light", L"\xd83d\xdc4d\xd83c\xdffb", TRUE},
    {"thumb-medium-light", L"\xd83d\xdc4d\xd83c\xdffc", TRUE},
    {"thumb-medium", L"\xd83d\xdc4d\xd83c\xdffd", TRUE},
    {"thumb-medium-dark", L"\xd83d\xdc4d\xd83c\xdffe", TRUE},
    {"thumb-dark", L"\xd83d\xdc4d\xd83c\xdfff", TRUE},
    {"woman-tech", L"\xd83d\xdc69\x200d\xd83d\xdcbb", TRUE},
    {"man-tech", L"\xd83d\xdc68\x200d\xd83d\xdcbb", TRUE},
    {"person-tech", L"\xd83e\xddd1\x200d\xd83d\xdcbb", TRUE},
    {"woman-tech-dark", L"\xd83d\xdc69\xd83c\xdfff\x200d\xd83d\xdcbb", TRUE},
    {"CN", L"\xd83c\xdde8\xd83c\xddf3", TRUE},
    {"US", L"\xd83c\xddfa\xd83c\xddf8", TRUE},
    {"JP", L"\xd83c\xddef\xd83c\xddf5", TRUE},
    {"GB", L"\xd83c\xddec\xd83c\xdde7", TRUE},
    {"EU", L"\xd83c\xddea\xd83c\xddfa", TRUE},
    {"family", L"\xd83d\xdc68\x200d\xd83d\xdc69\x200d\xd83d\xdc67\x200d\xd83d\xdc66", TRUE},
    {"rainbow", L"\xd83c\xdff3\xfe0f\x200d\xd83c\xdf08", TRUE},
    {"keycap-one", L"1\xfe0f\x20e3", TRUE},
    {"heart-fire", L"\x2764\xfe0f\x200d\xd83d\xdd25", TRUE},
    {"heart-VS16", L"\x2764\xfe0f", TRUE},
    {"smile-VS16", L"\x263a\xfe0f", TRUE},
    {"isolated-modifier", L"\xd83c\xdffb", FALSE},
    {"lone-high", L"\xd83d", FALSE},
    {"lone-low", L"\xde00", FALSE},
    {"mixed-profession", L"A\x4e2d\xd83d\xdc69\x200d\xd83d\xdcbb\x6587 Z", FALSE},
    {"adjacent-flags", L"\xd83c\xdde8\xd83c\xddf3\xd83c\xddfa\xd83c\xddf8", FALSE},
    {"unjoined-ZWJ", L"\xd83d\xde00 \x200d A", FALSE},
    {"tone-then-ZWJ", L"\xd83d\xdc4d\xd83c\xdffb \x200d A", FALSE},
    {"rtl-adjacent", L"\x05d0\x05d1 \xd83d\xdc69\x200d\xd83d\xdcbb \x05d2", FALSE},
};

int wmain(int argc, WCHAR **argv)
{
    const int width=1050, row=68, height=row*ARRAYSIZE(samples);
    BITMAPINFO bi={0}; BITMAPFILEHEADER fh={0}; BYTE *pixels=NULL;
    HDC dc; HBITMAP bitmap; HFONT font; HGDIOBJ old_bitmap,old_font;
    DWORD wrote; HANDLE out; int failures=0; WCHAR selected[LF_FACESIZE]={0};
    if(argc!=4)return 10;
    if(!AddFontResourceExW(argv[1],FR_PRIVATE,NULL))return 11;
    dc=CreateCompatibleDC(NULL);
    bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth=width;bi.bmiHeader.biHeight=-height;
    bi.bmiHeader.biPlanes=1;bi.bmiHeader.biBitCount=32;
    bitmap=CreateDIBSection(dc,&bi,DIB_RGB_COLORS,(void**)&pixels,NULL,0);
    if(!dc||!bitmap||!pixels)return 12;
    old_bitmap=SelectObject(dc,bitmap);
    font=CreateFontW(-40,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
       OUT_TT_ONLY_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,0,argv[2]);
    old_font=SelectObject(dc,font);GetTextFaceW(dc,LF_FACESIZE,selected);
    if(lstrcmpiW(selected,argv[2]))return 13;
    memset(pixels,255,width*height*4);SetBkMode(dc,TRANSPARENT);
    for(unsigned i=0;i<ARRAYSIZE(samples);i++) {
        const struct sample *s=&samples[i];int n=lstrlenW(s->text), dx[64]={0};
        SIZE size={0};SCRIPT_STRING_ANALYSIS a=NULL;
        HRESULT hr=ScriptStringAnalyse(dc,s->text,n,0,-1,SSA_GLYPHS,0,NULL,NULL,NULL,NULL,NULL,&a);
        const SIZE *shaped=SUCCEEDED(hr)?ScriptString_pSize(a):NULL;
        BOOL ok=GetTextExtentExPointW(dc,s->text,n,10000,NULL,dx,&size);
        if(!ok||!shaped||size.cx!=shaped->cx)failures++;
        if(ok && n && dx[n-1]!=size.cx)failures++;
        if(ok && n) {
            int unlimited[64]={0};SIZE again={0};
            if(!GetTextExtentExPointW(dc,s->text,n,0,NULL,unlimited,&again) ||
               again.cx!=size.cx || unlimited[n-1]!=size.cx)failures++;
        }
        if(ok && s->single && size.cx>0) {
            int fit=-1;SIZE again={0};
            if(!GetTextExtentExPointW(dc,s->text,n,size.cx-1,&fit,NULL,&again) || fit!=0)failures++;
            if(!GetTextExtentExPointW(dc,s->text,n,size.cx,&fit,NULL,&again) || fit!=n)failures++;
        }
        /* A composed emoji should occupy one em-sized cell, not two components.
         * Pixels must also be reviewed: equal widths alone do not prove composition. */
        if(s->single && (size.cx<=0 || size.cx>60))failures++;
        for(int j=1;j<n;j++)if(dx[j]<dx[j-1])failures++;
        printf("%s units=%d gdi=%ld shaped=%ld dx=",s->name,n,size.cx,shaped?shaped->cx:-1L);
        for(int j=0;j<n;j++)printf("%s%d",j?",":"",dx[j]);
        printf("\n");
        SelectObject(dc,GetStockObject(DEFAULT_GUI_FONT));
        TextOutA(dc,5,(int)i*row+8,s->name,(int)strlen(s->name));
        SelectObject(dc,font);
        for(int col=0;col<3;col++) {
            RECT r={200+col*280,(int)i*row+2,470+col*280,(int)(i+1)*row-2};
            FrameRect(dc,&r,(HBRUSH)GetStockObject(LTGRAY_BRUSH));
            if(!DrawTextW(dc,s->text,n,&r,DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX|
               (col==0?DT_LEFT:col==1?DT_CENTER:DT_RIGHT)))failures++;
        }
        if(a)ScriptStringFree(&a);
    }
    GdiFlush();out=CreateFileW(argv[3],GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    fh.bfType=0x4d42;fh.bfOffBits=sizeof(fh)+sizeof(BITMAPINFOHEADER);
    fh.bfSize=fh.bfOffBits+width*height*4;
    if(out==INVALID_HANDLE_VALUE)failures++;
    else {WriteFile(out,&fh,sizeof(fh),&wrote,NULL);WriteFile(out,&bi.bmiHeader,sizeof(BITMAPINFOHEADER),&wrote,NULL);
          WriteFile(out,pixels,width*height*4,&wrote,NULL);CloseHandle(out);}
    SelectObject(dc,old_font);SelectObject(dc,old_bitmap);
    DeleteObject(font);DeleteObject(bitmap);DeleteDC(dc);RemoveFontResourceExW(argv[1],FR_PRIVATE,NULL);
    printf("failures=%d\n",failures);return failures?1:0;
}
