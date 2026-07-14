/* Dependency header — its declarations must be EXCLUDED when bindgen
   is invoked with a file match of "sample.h". */
typedef unsigned int DepType;
extern DepType dep_func(int a);
