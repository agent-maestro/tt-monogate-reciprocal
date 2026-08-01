#include "Veml_reciprocal.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc,char**argv){ Verilated::commandArgs(argc,argv);
  auto*d=new Veml_reciprocal; auto tick=[&](){d->clk=0;d->eval();d->clk=1;d->eval();};
  d->rst=1;d->in_valid=0;for(int i=0;i<8;i++)tick();d->rst=0;
  std::vector<long long> dom; for(long long v=32;v<=4095;++v){dom.push_back(v);dom.push_back(-v);}
  const int LAT=17; const long long m=1LL<<15; std::vector<long long> out;
  d->in_valid=1;
  for(size_t k=0;k<dom.size();++k){ d->x_in=(int32_t)dom[k]; tick();
    long long y=(long long)(int32_t)d->result; out.push_back((y^m)-m); }
  for(int i=0;i<LAT+4;i++){tick(); long long y=(long long)(int32_t)d->result; out.push_back((y^m)-m);}
  for(size_t i=0;i<dom.size();++i) printf("%lld %lld\n", dom[i], out[i+LAT]);
  delete d; return 0; }
