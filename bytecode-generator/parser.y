/* DISCLAIMER: Most of bytecode directives follows jasmin 2.4 guide 
 * Most of the actions are defined as explained in Lectures and Backpatching algorithm * in dragon book 
 * References
 * Backpatching : 
 * https://www.isi.edu/~pedro/Teaching/CSCI565-Spring14/Materials/Backpatching.pdf
 * Bytecode :
 * https://en.wikipedia.org/wiki/Java_bytecode_instruction_listings
 */


%{
    #include <iostream>
    #include <unordered_map>
    #include <vector>
    #include <fstream>
    #include <cstring>
    #include <unordered_set>
    #include <stack>

    /*
     * Definitions of the input and output files
     */
    #define INPUT_FILE_NAME "input.txt"
    #define OUTPUT_FILE_NAME "bytecode.j"

    /*
     * Definitions for the header of the bytecode
     */
    #define OUTPUT_CLASS_NAME "Main"
    #define LIMIT_LOCALS ".limit locals 128"
    #define LIMIT_STACK ".limit stack 128"

    /*
     * Constant IDS reserved for System.out.println
     */
    #define SYSO_INT_VARID (1)  // Starts from 1 in java
    #define SYSO_FLOAT_VARID (2)

    /*
     * Start counting variable ids from 3
     */
    #define VARID_START (3)

    #define LABEL_OPTIONAL_PREFIX std::string("LABEL")
    #define LABEL(n) (LABEL_OPTIONAL_PREFIX + std::to_string(n))
    /* separator to remove all symbols until this symbol reached with each body block */
    #define SYMBOL_SEPARATOR "$"
    /*
     * Type of the declared variable
     * 3 allowed types: Integer, Float, and Boolean
     * Type is non in case of an error
     */
    enum VARTYPE{TYNONE=0, TYINTEGER, TYFLOAT, TYBOOLEAN};

    /*
     * Type of the Intruction
     * 3 allowed types: Integer, Float, and Boolean
     * Type is non in case of an error
     * Need the label type only to concat instructions to label
     */
    enum INSTTYPE{INST_NONE=0, INST_LABEL, INST_NORMAL, INST_GOTO, INST_FUNC, INST_JASMIN};

    /*
     * Stuff from flex that bison needs to know about:
     */
    extern int yylex();
    extern int yyparse();
    void yyerror(const char *);
    extern FILE *yyin;


    bool   codeHasError = false;
    extern int32_t lineNum; // Stores the line number from FLEX
    int32_t varID = VARID_START; // Start counting variable ids from 3 
    int32_t labelCounter = 0;	// Help generate labels

    /*
     * Struct to hold information of the instructions
     */
    struct instruction {
        std::string code;
        INSTTYPE type;
        /* Constructor */
        instruction(const std::string& instCode, INSTTYPE instType):
            code(instCode.c_str()), type(instType){}
    };

    std::vector<instruction> instructions; // Bytecode instructions
    std::string outputfileName; // File name of the output fie

    std::unordered_map<std::string, std::string> opInstructions =
    {
        /* Arithmetic operations */
        {"+", "add"},
        {"-", "sub"},
        {"*", "mul"},
        {"/", "div"},
        {"%", "rem"},

        /* Bitwise operation */
        {"|", "or"},
        {"&", "and"},
        
        /* Relational operations */
        {"==",  "\t\tif_icmpeq"},
        {"<=",  "\t\tif_icmple"},
        {">=",  "\t\tif_icmpge"},
        {"!=",  "\t\tif_icmpne"},
        {">",   "\t\tif_icmpgt"},
        {"<",   "\t\tif_icmplt"}
    };

    std::unordered_set<int32_t> prefixedLabels;
    std::unordered_map<std::string, std::pair<int32_t,VARTYPE> > symbolTable;
    std::stack<std::string> scopeSymbols;
    /*
     * Used with multiple declarations to temporarily hold variable names until flush
     */
    std::vector<std::string> temporaryVarNames; 
    
    /* Functions for parser processing */
    void addHeader();
    void addFooter();
    void addInstruction(const instruction&);
    std::string getOp(const std::string&);
    void addVariable(const std::string&, VARTYPE);
    void removeVariable(const std::string&);
    void addVarName(const std::string&);
    void flushVarNames(VARTYPE);
    void startSymbScope();
    void endSymbScope();
    bool checkVariableExists(const std::string&);
    std::string generateLabel();
    std::string getLabelString(int32_t n);

    /* For the backpatching algorithm explained in the dragon book */
    void backpatch(std::vector<int32_t> *, int32_t); 
    std::vector<int32_t> *mergeLists(std::vector<int32_t> *, std::vector<int32_t>*);
    // void typeCast(std::string, int32_t);
    void operationCast(const std::string&, int32_t, int32_t);

    /* Helper functions */
    void outBytecode();
%}

/*
 * Includes needed in union
 */
%code requires {
	#include <vector>
    #include <string>
}

%start method_body /* Define the starting symbol of the grammar */

%union {
    /* Using different int32_ts for readability */
    int32_t                      intValue;
    float                        floatValue;
    char*                        stringValue;
    bool                         booleanValue;
    char*                        varName;
    char*                        operationValue;
    struct {
        std::vector<int32_t>     *trueList, *falseList;
    } boolExpression;
    struct{
        std::vector<int32_t>     *nextList;
    } stmt;
    int32_t                  primType;
    int32_t                  expressionType;
}

/*
* By convention, Every non terminal is lower case, and every terminal is upper case
*/

/*
* Define each terminal symbol
*/

%token INTEGER_DECL FLOAT_DECL BOOLEAN_DECL 
%token IF_TOK ELSE_TOK WHILE_TOK FOR_TOK
%token LEFT_BRACKET RIGHT_BRACKET RIGHT_CURLY_BRACKET  LEFT_CURLY_BRACKET
%token SEMI_COLON
%token COMMA_TOK
%token ASSIGNMENT_OPERATOR
%token PRINTLN_TOK

/*
* Define the datatypes of the semantic values of some terminals
*/
%token <intValue>           INTEGER_NUMBER
%token <floatValue>         FLOAT_NUMBER
%token <stringValue>        STRING
%token <booleanValue>       BOOLEAN
%token <operationValue>     RELOP BOOLOP OPERATION
%token <varName>            IDENTIFIER

/*
* Define each nonterminal symbol
*/
%type  <intValue>           m
%type  <intValue>           goto_operation
%type  <primType>           primitive_type
%type  <expressionType>     expression
%type  <boolExpression>     boolean_expression
%type  <stmt>               statement
%type  <stmt>               statement_list
%type  <stmt>               if
%type  <stmt>               while
%type  <stmt>               for


/* Most of the actions are defined as explained in Lectures and Backpatching algorithm in dragon book */
/* backpatching : https://www.isi.edu/~pedro/Teaching/CSCI565-Spring14/Materials/Backpatching.pdf */

%%
/* Marker nonterminal (m) as explained in the dragon book with backpatching algorithm */
m:
    /* Empty*/
    {$$ = labelCounter; addInstruction({generateLabel() + ":", INSTTYPE::INST_LABEL});}
    ;

/* goto to be used with control structures */
goto_operation:
    /* Empty*/
    {$$ = instructions.size(); addInstruction({"\t\tgoto ",INSTTYPE::INST_GOTO});} /* goto will be resolved later by backpatching */
    ;

method_body:
    {addHeader();startSymbScope();} /* It's the start symbol so we will add the bytecode header first */
    statement_list m
    {backpatch($2.nextList, $3); addFooter();endSymbScope();} /* Code will end here so add the footer */
    ;

statement_list: 
    statement
    {$$.nextList = $1.nextList;}
    |
    statement_list m statement
    {backpatch($1.nextList, $2); $$.nextList = $3.nextList;}
    ;

statement:
    declaration
    {std::vector<int32_t> * newList = new std::vector<int32_t>(); $$.nextList = newList;}
    | 
    assignment
    {std::vector<int32_t> * newList = new std::vector<int32_t>(); $$.nextList = newList;}
    |
    print_func 
    {std::vector<int32_t> * newList = new std::vector<int32_t>(); $$.nextList = newList;}
    | 
    if
    {$$.nextList = $1.nextList;}
    | 
    while
    {$$.nextList = $1.nextList;}
    | 
    for
    {$$.nextList = $1.nextList;}
    ;

declaration:
    primitive_type IDENTIFIER declaration_extended SEMI_COLON
     {
        std::string varName($2);
        addVariable(varName, (VARTYPE)$1);
        flushVarNames((VARTYPE)$1);
     }
     ;

/* Non terminal for multiple variables declaration 
   int x , y , z;
*/
declaration_extended:
     COMMA_TOK IDENTIFIER declaration_extended
     {
         std::string varName($2);
         addVarName(varName);
     }
     |
    /* Empty */
    ;

primitive_type:
    INTEGER_DECL
    {$$ = VARTYPE::TYINTEGER;}
    |
    FLOAT_DECL
    {$$ = VARTYPE::TYFLOAT;}
    |
    BOOLEAN_DECL
    {$$ = VARTYPE::TYBOOLEAN;}
    ;

/* System.out.println non-terminal*/
print_func:
    PRINTLN_TOK LEFT_BRACKET
    { startSymbScope(); }
     STRING RIGHT_BRACKET
    { endSymbScope(); }
      SEMI_COLON
    {
        /* push System.out onto the stack */
        addInstruction({"\t\tgetstatic java/lang/System/out Ljava/io/PrintStream;",INSTTYPE::INST_FUNC});
        /* push a string onto the stack */
        addInstruction({"\t\tldc " + std::string($4), INSTTYPE::INST_NORMAL});
        /* call the PrintStream.println() method. */
        addInstruction({"\t\tinvokevirtual java/io/PrintStream/println(Ljava/lang/String;)V",INSTTYPE::INST_FUNC});
    }
    |
 	PRINTLN_TOK LEFT_BRACKET expression RIGHT_BRACKET SEMI_COLON
 	{
        /* Expression is on top of stack so just push System.out 
         * onto the stack and invoke 
         * but we need to store the expression first in a temp var so we can load it *- * again before calling 
         */
        if ($3 == VARTYPE::TYINTEGER) {
            std::string tempVarName = std::to_string(SYSO_INT_VARID);
            addInstruction({"\t\tistore " + tempVarName, INSTTYPE::INST_NORMAL});
            addInstruction({"\t\tgetstatic java/lang/System/out Ljava/io/PrintStream;", INSTTYPE::INST_FUNC});
            addInstruction({"\t\tiload " + tempVarName, INSTTYPE::INST_NORMAL});
            addInstruction({"\t\tinvokevirtual java/io/PrintStream/println(I)V", INSTTYPE::INST_FUNC});
        } else if ($3 == VARTYPE::TYFLOAT) {
            std::string tempVarName = std::to_string(SYSO_FLOAT_VARID);
            addInstruction({"\t\tfstore " + tempVarName, INSTTYPE::INST_NORMAL});
            addInstruction({"\t\tgetstatic java/lang/System/out Ljava/io/PrintStream;", INSTTYPE::INST_FUNC});
            addInstruction({"\t\tfload " + tempVarName, INSTTYPE::INST_NORMAL});
            addInstruction({"\t\tinvokevirtual java/io/PrintStream/println(F)V", INSTTYPE::INST_FUNC});
        }
 	}
   
 	;

if:
    IF_TOK LEFT_BRACKET boolean_expression RIGHT_BRACKET LEFT_CURLY_BRACKET
    { startSymbScope(); }
    m statement_list goto_operation
    RIGHT_CURLY_BRACKET
    { endSymbScope(); }
    ELSE_TOK LEFT_CURLY_BRACKET
    { startSymbScope(); }
    m statement_list
    RIGHT_CURLY_BRACKET
    {
        endSymbScope();
        /* Fix the 2 goto for location markers by backpatching */
        backpatch($3.trueList, $7);
		backpatch($3.falseList, $15);
        /* Fix the next lists for this if */
		$$.nextList = mergeLists($8.nextList, $16.nextList);
		$$.nextList->push_back($9);
    }
    ;

while:
    WHILE_TOK m LEFT_BRACKET boolean_expression RIGHT_BRACKET m LEFT_CURLY_BRACKET 
    { startSymbScope(); }
    statement_list
    RIGHT_CURLY_BRACKET
    {
        endSymbScope();
        backpatch($9.nextList,$2);
        backpatch($4.trueList,$6);
        $$.nextList = $4.falseList;
        addInstruction({"\t\tgoto " + getLabelString($2), INSTTYPE::INST_GOTO});
    }
    ;

for:
    FOR_TOK LEFT_BRACKET for_assignment SEMI_COLON m boolean_expression SEMI_COLON
    m for_assignment goto_operation
    RIGHT_BRACKET LEFT_CURLY_BRACKET
    { startSymbScope(); }
    m statement_list goto_operation
	RIGHT_CURLY_BRACKET
    {
        endSymbScope(); 
        backpatch($6.trueList, $14);
		std::vector<int32_t> * newList = new std::vector<int32_t>();
		newList->push_back($10);
		backpatch(newList,$5);
		newList = new std::vector<int32_t>();
		newList->push_back($16);
		backpatch(newList,$8);
		backpatch($15.nextList,$8);
		$$.nextList = $6.falseList;
    }
    ;

for_assignment:
    IDENTIFIER ASSIGNMENT_OPERATOR expression
    {
        /* Expression result on top of the stack */
        std::string varName($1);
		if (checkVariableExists(varName)) {
            std::string varID = std::to_string(symbolTable[varName].first);
			if ($3 == symbolTable[varName].second) {
                std::string varID = std::to_string(symbolTable[varName].first);
				if ($3 == VARTYPE::TYINTEGER) {
					addInstruction({"\t\tistore " + varID, INSTTYPE::INST_NORMAL});
				} else if ($3 == VARTYPE::TYFLOAT) {
					addInstruction({"\t\tfstore " + varID, INSTTYPE::INST_NORMAL});
				}
			}
			else {
		        yyerror("Invalid assignment, Two different datatypes.");
			}
		}
    }
    ;

assignment:
    IDENTIFIER ASSIGNMENT_OPERATOR expression SEMI_COLON
    {
        /* Expression result on top of the stack */
        std::string varName($1);
		if (checkVariableExists(varName)) {
            std::string varID = std::to_string(symbolTable[varName].first);
			if ($3 == symbolTable[varName].second) {
                std::string varID = std::to_string(symbolTable[varName].first);
				if($3 == VARTYPE::TYINTEGER) {
					addInstruction({"\t\tistore " + varID, INSTTYPE::INST_NORMAL});
				} else if ($3 == VARTYPE::TYFLOAT) {
					addInstruction({"\t\tfstore " + varID, INSTTYPE::INST_NORMAL});
				}
			}
			else {
		        yyerror("Invalid assignment, Two different datatypes.");
			}
		}
    }
    ;

expression:
    INTEGER_NUMBER
    {$$ = VARTYPE::TYINTEGER;  addInstruction({"\t\tldc "+ std::to_string($1), INSTTYPE::INST_NORMAL});} 
    |
    FLOAT_NUMBER
    {$$ = VARTYPE::TYFLOAT;  addInstruction({"\t\tldc "+ std::to_string($1), INSTTYPE::INST_NORMAL});} 
    |
    expression OPERATION expression
    {operationCast(std::string($2), $1, $3);}
    |
    IDENTIFIER
    {
        /* Make sure the id exists first then load it */
		std::string varName($1);
		if (checkVariableExists(varName)) {
			$$ = symbolTable[varName].second;
            std::string varID = std::to_string(symbolTable[varName].first);

			if (symbolTable[varName].second == VARTYPE::TYINTEGER) {
				addInstruction({"\t\tiload " + varID, INSTTYPE::INST_NORMAL});
			} else if (symbolTable[varName].second == VARTYPE::TYFLOAT) {
				addInstruction({"\t\tfload " + varID, INSTTYPE::INST_NORMAL});
			}

		} else {
			$$ = VARTYPE::TYNONE;
		}
	}
    |
    LEFT_BRACKET expression RIGHT_BRACKET
    {$$ = $2;}
    ;

boolean_expression:
	BOOLEAN
    {
        $$.trueList = new std::vector<int32_t>();
        $$.falseList = new std::vector<int32_t>();

        if ($1 == true) 
            $$.trueList->push_back(instructions.size());
		else 
            $$.falseList->push_back(instructions.size());

        addInstruction({"\t\tgoto ", INSTTYPE::INST_GOTO});
    }
    |
    expression RELOP expression
    {
		std::string operation($2);
		$$.trueList = new std::vector<int32_t>();
		$$.trueList->push_back(instructions.size());
		$$.falseList = new std::vector<int32_t>();
		$$.falseList->push_back(instructions.size() + 1);
		addInstruction({getOp(operation)+ " ", INSTTYPE::INST_NORMAL});
		addInstruction({"\t\tgoto ", INSTTYPE::INST_GOTO});
	}
	|
    boolean_expression BOOLOP m boolean_expression
    {
        if (strcmp($2, "&&") == 0) {
			backpatch($1.trueList, $3);
			$$.trueList = $4.trueList;
			$$.falseList = mergeLists($1.falseList,$4.falseList);
		} else if (strcmp($2, "||") == 0) {
			backpatch($1.falseList,$3);
			$$.trueList = mergeLists($1.trueList, $4.trueList);
			$$.falseList = $4.falseList;
		}
    }
	;

%%



int main (int argv, char * argc[])
{
	FILE *fileDesc;
	if (argv == 1) {
		fileDesc = fopen(INPUT_FILE_NAME, "r");
		outputfileName = OUTPUT_FILE_NAME;
	} else {
		fileDesc = fopen(argc[1], "r");
		outputfileName = std::string(argc[1]);
	}
	if (fileDesc == NULL) {
		std::cout << "Error opening the file" << std::endl;
		return -1;
	}
	yyin = fileDesc;
	yyparse();
    if (codeHasError == false) {
	outBytecode();
    }
    return 0;
}

/*------------------------------------------------------------------------
 * yyerror  - Prints syntax errors in the input files
 *------------------------------------------------------------------------
 */

void yyerror(const char * errorString)
{
    codeHasError = true;
	printf("Error at Line %d: %s\n", lineNum, errorString);
}

/*------------------------------------------------------------------------
 * addHeader  - adds the default header bytecode for any java compiled program
 *------------------------------------------------------------------------
 */
void addHeader()
{
    addInstruction({".source " + std::string(OUTPUT_FILE_NAME), INSTTYPE::INST_JASMIN});
	addInstruction({".class public " + std::string(OUTPUT_CLASS_NAME), INSTTYPE::INST_JASMIN});
    addInstruction({".super  java/lang/Object", INSTTYPE::INST_JASMIN});
	addInstruction({".method public <init>()V", INSTTYPE::INST_JASMIN});
	addInstruction({"aload_0", INSTTYPE::INST_NORMAL});
	addInstruction({"invokenonvirtual java/lang/Object/<init>()V", INSTTYPE::INST_NORMAL});
	addInstruction({"return", INSTTYPE::INST_NORMAL});
	addInstruction({".end method", INSTTYPE::INST_NORMAL});
	addInstruction({".method public static main([Ljava/lang/String;)V", INSTTYPE::INST_NORMAL});
    addInstruction({LIMIT_LOCALS, INSTTYPE::INST_NORMAL});
    addInstruction({LIMIT_STACK, INSTTYPE::INST_NORMAL});
}

/*------------------------------------------------------------------------
 * addFooter  -   Adds the default footer bytecode for any java compiled program
 *------------------------------------------------------------------------
 */
void addFooter()
{
	addInstruction({"return", INSTTYPE::INST_NORMAL});
	addInstruction({".end method", INSTTYPE::INST_NORMAL});
}

/*------------------------------------------------------------------------
 * addInstruction  -  Adds instruction to the generated bytecode
 *------------------------------------------------------------------------
 */
void addInstruction(const instruction& instr)
{
    instructions.push_back(instr);
}

/*------------------------------------------------------------------------
 * getOp  - Get the specified operation from the hashmap
 *------------------------------------------------------------------------
 */
std::string getOp(const std::string& op) 
{
    auto iterator = opInstructions.find(op);
    if (iterator != opInstructions.end()) {
		return iterator->second;
	}
	return "";
}

/*------------------------------------------------------------------------
 * addVariable  - Adds a variable to the symbol table
 *------------------------------------------------------------------------
 */
void addVariable(const std::string& name,VARTYPE type) 
{

    if (symbolTable.find(name) != symbolTable.end()) {
		std::string error = name + " was declared before.";
		yyerror(error.c_str());
	} else {
        std::string currVariableID = std::to_string(varID); // get new id
		if (type == VARTYPE::TYINTEGER) {
			addInstruction({"\t\ticonst_0", INSTTYPE::INST_NORMAL});
            addInstruction({"\t\tistore " + currVariableID, INSTTYPE::INST_NORMAL});
		}
		else if ( type == VARTYPE::TYFLOAT) {
			addInstruction({"\t\tfconst_0", INSTTYPE::INST_NORMAL});
            addInstruction({"\t\tfstore " + currVariableID, INSTTYPE::INST_NORMAL});
		}
		symbolTable[name] = std::make_pair(varID, type);
        varID++;
        
        scopeSymbols.push(name);
	}
}
/*------------------------------------------------------------------------
 * removeVariable  - Removes a variable from the symbol table
 *------------------------------------------------------------------------
 */
void removeVariable(const std::string& name){
    if (symbolTable.find(name) != symbolTable.end()) {
            symbolTable.erase(name);
    }
}
/*------------------------------------------------------------------------
 * checkVariableExists  - Check if variable exists and print error if not
 *------------------------------------------------------------------------
 */
 bool checkVariableExists(const std::string& varName) 
 {
    if (symbolTable.find(varName) != symbolTable.end())
        return true;
    else {
        std::string error = varName + " wasn't declared in this scope.";
        yyerror(error.c_str());
        return false;
    }
 }

/*------------------------------------------------------------------------
 * generateLabel  - Generates a new label for the code 
 *                  and increment the label counter
 *------------------------------------------------------------------------
 */
std::string generateLabel() 
{
    return LABEL(labelCounter++);
}

/*------------------------------------------------------------------------
 * backpatch  - Adds jump location for a goto [as explained in the dragon book]
 *------------------------------------------------------------------------
 */
void backpatch(std::vector<int32_t> *list, int32_t jmploc) 
{
    if (list != nullptr) {
        for(int32_t codeLoc : *list) {
		    instructions[codeLoc].code = instructions[codeLoc].code + getLabelString(jmploc);
	    }
    }
}

/*------------------------------------------------------------------------
 * merge  - Merge two lists contents together
 *------------------------------------------------------------------------
 */
std::vector<int32_t> *mergeLists(std::vector<int32_t> *list1, std::vector<int32_t> *list2) 
{
    if (list1 != nullptr && list2 != nullptr) {
		std::vector<int32_t> *outList = new std::vector<int32_t> (*list1);
		outList->insert(outList->end(), list2->begin(),list2->end());
		return outList;
	} else if (list1 != nullptr) {
		return list1;
	} else if (list2 != nullptr) {
		return list2;
	}
	return new std::vector<int32_t>();
}
 /*------------------------------------------------------------------------
 * operationCast  -  Check if 2 variables are equal type otherwise not handled ?
 *------------------------------------------------------------------------
 */
void operationCast(const std::string& operation,int32_t varType1, int32_t varType2) 
{
    if (varType1 == varType2) {
		if (varType1 == VARTYPE::TYINTEGER) {
			addInstruction({"\t\ti" + getOp(operation), INSTTYPE::INST_NORMAL});
		} else if (varType1 == VARTYPE::TYFLOAT) {
			addInstruction({"\t\tf" + getOp(operation), INSTTYPE::INST_NORMAL});
		}
	}
	else {
		yyerror("The two expressions are not the same datatype");//TODO
	}
}

/*------------------------------------------------------------------------
 * addVarName  -  Temporarily store var name to a buffer
 *------------------------------------------------------------------------
 */
void addVarName(const std::string& varName) 
{
    temporaryVarNames.push_back(varName);
}

/*------------------------------------------------------------------------
 * flushVarNames  -  Flush the buffer content to the symbol table with given type
 *------------------------------------------------------------------------
 */
void flushVarNames(VARTYPE type) 
{
    for (std::string varName : temporaryVarNames) {
        addVariable(varName, type);
    }
    temporaryVarNames.clear();
}
/*------------------------------------------------------------------------
 * startSymbScope  -  adds a separator to the stack so i can easily 
 *------------------------------------------------------------------------
 */
void startSymbScope(){
    scopeSymbols.push(SYMBOL_SEPARATOR);
}
/*------------------------------------------------------------------------
 * endSymbScope  -  removes all symbols added in the symbol table in the last scope
 *------------------------------------------------------------------------
 */
void endSymbScope(){
    if(scopeSymbols.empty() == false){
        while(scopeSymbols.top() != SYMBOL_SEPARATOR){
            removeVariable(scopeSymbols.top());
            scopeSymbols.pop();
        }
        scopeSymbols.pop();
    }

}

/*------------------------------------------------------------------------
 * getLabelString  -  Check if label needs a prefix and return label accordingly
 *------------------------------------------------------------------------
 */
std::string getLabelString(int32_t n) 
{
    return LABEL(n);
}


/*------------------------------------------------------------------------
 * outBytecode  -  Writes the output bytecode to a file
 *------------------------------------------------------------------------
 */
void outBytecode() 
{
    std::ofstream fout(outputfileName);
    if (fout.is_open()) {
        for (const instruction& instr : instructions) {
		    fout << instr.code << std::endl;
	    }
    } else {
        std::cout << "Error opening the file !" << std::endl;
    }
    fout.close();
}