structure Test = struct
open Dojo infix >>=

local val postruns = ref nil
in fun postruns_add f = postruns := f :: !postruns
   fun postruns_run () = List.app (fn s => s()) (!postruns)
end

fun getElem id : Js.elem =
    case Js.getElementById Js.document id of
        SOME e => e
      | NONE => raise Fail "getElem"

(* User Code *)

val treedata = [
[("id","0"),("name","World"),("kind","folder")],
[("id","1"),("name","Europe"),("parent","0"),("kind","folder")],
[("id","2"),("name","Africa"),("parent","0")],
[("id","3"),("name","North America"),("parent","0"),("kind","folder")],
[("id","4"),("name","Germany"),("parent","1")],
[("id","5"),("name","Denmark"),("parent","1")],
[("id","6"),("name","Italy"),("parent","1")],
[("id","7"),("name","Norway"),("parent","1")],
[("id","8"),("name","Asia"),("parent","0")],
[("id","9"),("name","USA"),("parent","3")],
[("id","10"),("name","Canada"),("parent","3")],
[("id","11"),("name","Mexico"),("parent","3")]
]

val () = print "<link rel='stylesheet' href='dojo/resources/dojo.css'>"
val () = print "<link rel='stylesheet' href='dijit/themes/claro/claro.css'>"
val () = print "<link rel='stylesheet' href='dgrid/css/dgrid.css'>"
val () = print "<link rel='stylesheet' href='dgrid/css/skins/claro.css'>"
val () = print "<style>html, body, #mainDiv { width: 100%; height: 100%; border: 0; padding: 0; margin: 0;}\n.dgrid-row { height: 22px; }\n.dgrid-row-odd { background: '#F2F5F9'; }\n.dgrid-cell { border: none; }\n.dgrid { border: none; height: 100%; }</style>"
val () = print "<body class='claro' id='body'></body>"

(* Filtering select data *)
val selectdata = ["Dog", "Horse", "Cat", "Mouse", "Cow", "Elephant", "Turtle", "Tiger", "Camel", "Sheep", "Deer", "Bat", "Catfish", "Donkey", "Duck", "Bear"]
val selectdata = #2(List.foldl (fn (x,(i,a)) => (i+1,{id=Int.toString i,name=x}::a)) (0,nil) selectdata)

(* Grid widget *)

val gridData =
    [[("first","Hans"),("last","Eriksen"),("age", "45")],
     [("first","Grethe"),("last","Hansen"),("age", "25")],
     [("first","Jens"),("last","Ulrik"),("age", "8")]]

val gridM = 
    Grid.mk [("sort","last"),("className","dgrid-autoheight")] 
            [("first", "First Name"),
             ("last", "Last Name"),
             ("age", "Age")]

fun onClick w g rg (id,n) = (setContent w ("Got " ^ n ^ " - " ^ id);
                             startup rg;
                             Grid.add g gridData)


open Js.Element infix &

val outputElem = tag "div" ($"This is just an empty area, initially!")

fun button_handler theform username password age birthdate fselect () =
    if Form.validate theform then
      let val un = TextBox.getValue username
          val pw = TextBox.getValue password
          val age = NumberTextBox.getValue age
          val bd = DateTextBox.getValue birthdate
          val animal = FilteringSelect.getValue fselect
      in Js.appendChild outputElem (tag "p" ($("{un=" ^ un ^ ",pw=" ^ pw ^ ",age=" ^ age ^ ",birthdate=" ^ bd ^ ",animal=" ^ animal ^ "}")))
      end
    else Js.appendChild outputElem (tag "p" ($("Form not valid!")))

fun form theform username password age birthdate evennum fselect button =
    let val e =
          tag "table" (
            tag "tr" (tag "td" ($"Username") & tag "td" (TextBox.domNode username)) &
            tag "tr" (tag "td" ($"Password") & tag "td" (TextBox.domNode password)) &
            tag "tr" (tag "td" ($"Age") & tag "td" (NumberTextBox.domNode age)) &
            tag "tr" (tag "td" ($"Birthdate") & tag "td" (DateTextBox.domNode birthdate)) &
            tag "tr" (tag "td" ($"Evennum") & tag "td" (ValidationTextBox.domNode evennum)) &
            tag "tr" (tag "td" ($"Favorite animal") & tag "td" (FilteringSelect.domNode fselect)) &
            tag "tr" (taga "td" [("align","center"),("colspan","2")] (Button.domNode button)))
        val f = Form.domNode theform
    in Js.appendChild f e;
       f
    end

val restGrid =
  let open RestGrid
      val colspecs = [VALUE {field="gid",label="gid",editor=NONE,sortable=true},
                      VALUE {field="name",label="Name",editor=SOME "text",sortable=true},
                      VALUE {field="email",label="Email",editor=SOME "text",sortable=true},
                      VALUE {field="comments",label="Comments",editor=SOME "text",sortable=true}(*,
                      DELETE {label="Action"}*)]
  in RestGrid.mk {target="http://localhost:8080/rest/guests", idProperty="gid"} colspecs >>= (fn rg =>
     ret (RestGrid.toWidget rg))
  end

fun panes rg n =
    if n = 0 then ret []
    else pane [("title", "Tab" ^ Int.toString n),EditorIcon.newPage] (Js.Element.$"") >>= (fn p =>
         (if n = 2 then addChild p rg else ();
         panes rg (n-1) >>= (fn ps =>
         ret (p::ps))))

fun validator s = case Int.fromString s of SOME i => i mod 2 = 0 
                                         | NONE => false

val m =
  TextBox.mk [] true >>= (fn username =>
  TextBox.mk [("type","password")] true >>= (fn password =>
  NumberTextBox.mk [] true >>= (fn age =>
  DateTextBox.mk [] false >>= (fn birthdate =>
  ValidationTextBox.mk [] {required=true,validator=validator} >>= (fn evennum =>
  FilteringSelect.mk [("name","animal"),("searchAttr","name"),("value", "3"),("maxHeight","150")] selectdata >>= (fn fselect =>
  (postruns_add (fn() => FilteringSelect.startup fselect);
  Form.mk [] >>= (fn theform =>
  Button.mk [("label","Login")] (button_handler theform username password age birthdate fselect) >>= (fn button =>
  pane [("region", "top")] (tag "b" ($"Main Title")) >>= (fn toppane =>
  pane [("style","height:auto;")] outputElem >>= (fn botpane =>
  titlePane [("title","Output"),("region", "bottom"),
         ("splitter","true"), ("style","border:0;")] botpane >>= (fn botpane =>
  linkPane [("region", "right"), ("href","doc/ARRAY.sml.html"), ("style", "width:20%;"),
            ("splitter","true")] >>= (fn rightpane =>
  pane [("title", "First"),("closable","true"),EditorIcon.unlink] ($"Initially empty") >>= (fn p1 =>
  pane [("title", "Second"),EditorIcon.save] (tag "h2" ($"A form") & form theform username password age birthdate evennum fselect button) >>= (fn p2 =>
  gridM >>= (fn g =>
  pane [("title", "Grid"),("style","padding:0;border:0;margin:0;")] (Grid.domNode g) >>= (fn gridWidget =>
  restGrid >>= (fn rg =>
  treeStore treedata >>= (fn store =>
  tree [] "0" (onClick p1 g rg) store >>= (fn tr =>
  panes rg 4 >>= (fn ps =>
  accordionContainer [("title","Something"),("region","right"),
                      ("splitter","true")] ps >>= (fn ac =>
  tabContainer [("region","center"),("tabPosition","bottom")] [p1,p2,gridWidget,ac] >>= (fn tc =>
  borderContainer [("region","center"),
                   ("style", "height: 100%; width: 100%;")] [tc,botpane] >>= (fn ibc =>
  titlePane [("title","A Tree"),("region","left"),("splitter","true"),
             ("style","width:10%;")] tr >>= (fn tr =>
  borderContainer [("style", "height: 100%; width: 100%;")]
                  [tr,ibc,toppane,rightpane]
)))))))))))))))))))))))))

fun setWindowOnload (f: unit -> unit) : unit =
    let open JsCore infix ==>
    in exec1{arg1=("a", unit ==> unit),
             stmt="return window.onload=a;",
             res=unit} f
    end

val () = setWindowOnload (fn () => (attachToElement (getElem "body") m;
                                    postruns_run()))
end