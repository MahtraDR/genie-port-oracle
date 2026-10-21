# WP12: the exact <% %> block of DR-Genie-Scripts SkillData.cmd (rows 11-24) under Jint 4.
var skills Bow|Athletics
echo start
<%
	list = getVar('skills').toString();
	list = list.split("|");
	for(i = 0; i < list.length() - 1; i++)
	{
		if(list[i].localeCompare(list[i+1]) == 1) {
			var temp = list[i];
			list[i] = list[i+1];
			list[i+1] = temp;
			i = -1;
		}
	}
	setVar('skills',list.join("|"));
%>
echo not-here
