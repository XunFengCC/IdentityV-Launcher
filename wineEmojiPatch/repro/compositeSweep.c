#include <windows.h>
#include <usp10.h>
#include <stdio.h>
#define ARRAY_SIZE ARRAYSIZE
#include "emoji_rgi_sequences.h"
int wmain(int argc,WCHAR **argv) {
 if(argc!=3)return 2;
 if(!AddFontResourceExW(argv[1],FR_PRIVATE,0))return 3;
 HDC dc=CreateCompatibleDC(NULL);HFONT f=CreateFontW(-40,0,0,0,400,0,0,0,1,0,0,0,0,argv[2]);SelectObject(dc,f);
 int failed=0,items_failed=0,glyphs_failed=0,extents_failed=0;
 ULONGLONG start=GetTickCount64();
 for(unsigned t=0;t<ARRAYSIZE(emoji_rgi_sequences);t++) {
  const struct emoji_rgi_sequence *e=&emoji_rgi_sequences[t];const WCHAR *text=emoji_rgi_data+e->offset;
  SCRIPT_ITEM items[32];SCRIPT_CONTROL c={0};SCRIPT_STATE s={0};int nr=0,ng=0;WORD g[64],m[64];SCRIPT_VISATTR v[64];SCRIPT_CACHE cache=NULL;
  SIZE size={0};int dx[64]={0},bad=0;
  HRESULT hr=ScriptItemize(text,e->length,31,&c,&s,items,&nr);
  if(FAILED(hr)||nr!=1){bad=1;items_failed++;}
  if(!bad){
   hr=ScriptShape(dc,&cache,text,e->length,64,&items[0].a,g,m,v,&ng);
   if(FAILED(hr)||ng!=1||g[0]==0||g[0]==0xffff||v[0].fZeroWidth){bad=1;glyphs_failed++;}
  }
  if(!GetTextExtentExPointW(dc,text,e->length,0,NULL,dx,&size)||size.cx<=0||size.cx>60||dx[e->length-1]!=size.cx){bad=1;extents_failed++;}
  if(bad){if(failed<30){printf("FAIL t=%u runs=%d glyphs=%d width=%ld lastdx=%d text=",t,nr,ng,size.cx,dx[e->length-1]);for(int j=0;j<e->length;j++)printf("%04x ",text[j]);puts("");}failed++;}
  ScriptFreeCache(&cache);
 }
 printf("total=%u failed=%d itemize=%d glyphs=%d extents=%d elapsed_ms=%llu\n",(unsigned)ARRAYSIZE(emoji_rgi_sequences),failed,items_failed,glyphs_failed,extents_failed,GetTickCount64()-start);
 return failed?1:0;
}
